# Copyright (C) 2013 ClearStory Data, Inc.
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'chef/knife'

module KnifeSafeUpload

  class KnifeConfigParser
    attr_reader :knife

    def initialize(knife_conf_path)
      @knife = {}
      instance_eval(IO.read(knife_conf_path))
    end

    def cookbook_path(path_list)
      @cookbook_path_list = path_list
    end

    def get_cookbook_path_list
      @cookbook_path_list
    end

    def method_missing(meth, *args, &block)
      # skip
    end
  end

  module Utils
    class << self
      def sort_hash_keys(h)
        Hash[*h.sort.flatten(1)]
      end

      def recursive_sort_hash_keys(obj)
        if [Hash, Hashie::Mash, VariaModel::Attributes].include?(obj.class)
          Hash[*obj.sort.map {|k, v| [k, recursive_sort_hash_keys(v)] }.flatten(1)]
        elsif obj.instance_of?(Array)
          obj.map {|element| recursive_sort_hash_keys(element) }
        else
          obj
        end
      end

      def json_with_sorted_keys(h)
        JSON.pretty_generate(recursive_sort_hash_keys(h)) + "\n"
      end
    end
  end

  module DataBagUtils
    class << self
      def decrypted_attributes(data_bag_item)
        begin
          [data_bag_item.decrypt.clone, true]
        rescue OpenSSL::Cipher::CipherError, NoMethodError, NotImplementedError, ArgumentError => ex
          [data_bag_item.attributes.clone, false]
        end
      end
    end
  end

  module BaseCommandMixin
    def self.included(includer)
      includer.class_eval do
        deps do
          require 'ridley'
          require 'diffy'
        end

        option :pattern,
          :short => '-p PATTERN',
          :long => '--pattern PATTERN',
          :description => 'A regular expression pattern to restrict the set of objects to ' +
                          'manipulate',
          :proc => Proc.new { |value| Chef::Config[:knife][:pattern] = value }

        option :debug,
          :long => '--debug',
          :description => 'Turn on debug messages',
          :proc => Proc.new { |value| Chef::Config[:knife][:debug] = value }
      end
    end
  end

  class BaseCommand < Chef::Knife

    def initialize(args)
      super
      @pattern = locate_config_value(:pattern)
      if @pattern
        @pattern = Regexp.new(@pattern)
      else
        @pattern = //
      end
    end

    def diff(a, b)
      ::Diffy::Diff.new(a, b, :context => 2)
    end

    def diff_color(a, b)
      diff(a, b).to_s(ui.color? ? :color : :text)
    end

    def debug(msg)
      if locate_config_value(:debug)
        ui.info("DEBUG: #{msg}")
      end
    end

    def fatal_error(msg)
      ui.fatal(msg)
      exit(1)
    end

    def locate_config_value(key, kind = :optional)
      raise unless [:required, :optional].include?(kind)
      key = key.to_sym
      value = config[key] || Chef::Config[:knife][key]
      if kind == :required && value.nil?
        fatal_error("#{key} not specified")
      end
      value
    end

    def get_knife_config_path
      locate_config_value(:config_file, :required)
    end

    def parsed_knife_config
      unless @parsed_knife_config
        @parsed_knife_config = KnifeConfigParser.new(get_knife_config_path)
      end

      @parsed_knife_config
    end

    def get_cookbooks_path
      unless @cookbooks_path
        path_list = parsed_knife_config.get_cookbook_path_list
        path_list.each do |path|
          if ['.git', 'environments', 'data_bags'].map do |subdir_name|
            File.directory?(File.join(path, subdir_name))
          end.all?
            @cookbooks_path = path
          end
        end

        raise "No cookbooks repository checkout path found in #{path_list}" unless @cookbooks_path
      end

      @cookbooks_path
    end

    def ridley
      unless @ridley
        knife_conf_path = get_knife_config_path

        # Check file existence (Ridley will throw a confusing error).
        raise "File #{knife_conf_path} does not exist" unless File.file?(knife_conf_path)

        @ridley = Ridley.from_chef_config(knife_conf_path, :ssl => { :verify => false })
        data_bag_secret_file_path = @ridley.options[:encrypted_data_bag_secret]
        unless data_bag_secret_file_path
          raise "No encrypted data bag secret location specified in #{knife_conf_path}"
        end

        unless File.file?(data_bag_secret_file_path)
          raise "File #{data_bag_secret_file_path} does not exist"
        end

        # The encrypted data bag secret has to be the value, even though the readme in Ridley 1.5.2
        # says it can also be a file name, so we have to re-create the Ridley object.
        @ridley = Ridley.new(
          server_url: @ridley.server_url,
          client_name: @ridley.client_name,
          client_key: @ridley.client_key,
          encrypted_data_bag_secret: IO.read(data_bag_secret_file_path),
          ssl: { verify: false }
        )
      end

      @ridley
    end

    def report_errors(&block)
      begin
        yield
      rescue => exception
        ui.fatal("#{exception}: #{exception.backtrace.join("\n")}")
        raise exception
      end
    end

  end

  class DataBagCommand < BaseCommand

    def list_data_bag_item_files(bag_name)
      Dir[File.join(get_data_bag_dir(bag_name), '*.json')].select do |file_path|
        data_bag_item_id_from_path(file_path) =~ @pattern
      end
    end

    def list_data_bag_item_ids(bag_name)
      list_data_bag_item_files(bag_name).map {|item_path| data_bag_item_id_from_path(item_path) }
    end

    def data_bag_item_id_from_path(item_path)
      File::basename(item_path).gsub(/\.json$/, '')
    end

    def override_attributes(item, new_attributes)
      item.attributes.clear
      item.from_hash(new_attributes)
    end

    def diff_data_bag_item(item, item_id, old_attributes, new_attributes, diff_comment_prefix,
                           desc1, desc2)
      old_attributes_formatted = Utils.json_with_sorted_keys(old_attributes)
      new_attributes_formatted = Utils.json_with_sorted_keys(new_attributes)

      if old_attributes_formatted == new_attributes_formatted
        ui.info("#{item_id} has no differences (no decryption attempted)")
        return false
      end

      override_attributes(item, old_attributes)
      old_decrypted, old_could_decrypt = DataBagUtils.decrypted_attributes(item)

      override_attributes(item, new_attributes)
      new_decrypted, new_could_decrypt = DataBagUtils.decrypted_attributes(item)

      if old_could_decrypt != new_could_decrypt
        if old_could_decrypt
          ui.warn("Could decrypt the old version of item #{item_id} but not the new one")
        else
          ui.warn("Could decrypt the new version of item #{item_id} but not the old one")
        end
      end

      old_decrypted_formatted = Utils.json_with_sorted_keys(old_decrypted)
      new_decrypted_formatted = Utils.json_with_sorted_keys(new_decrypted)

      # Encrypted data could differ but decrypted data could still be the same.
      if old_decrypted_formatted == new_decrypted_formatted
        ui.info("#{item_id} has differences before decryption but no differences after decryption")
        return false
      end

      ui.info("#{diff_comment_prefix} data bag item #{item_id} " +
              "(#{old_could_decrypt ? 'decrypted' : 'raw'} #{desc1} vs." +
              " #{new_could_decrypt ? 'decrypted' : 'raw'} #{desc2}):\n" +
              diff_color(old_decrypted_formatted, new_decrypted_formatted) + "\n")
      true
    end

    def set_data_bag_items(bag_name)
      ensure_data_bag_dir_exists(bag_name)

      data_bag = ridley.data_bag.find(bag_name)

      processed_items = Set.new()
      ignored_items = Set.new()
      updated_items = Set.new()

      verb = @dry_run ? 'Would update' : 'Updating'

      data_bag.item.all.sort_by {|item| item.chef_id }.each do |item|
        item_id = item.chef_id
        unless item_id =~ @pattern
          ignored_items << item_id
          next
        end

        processed_items << item_id

        new_attributes = load_data_bag_item_file(bag_name, item_id, :can_skip)
        next unless new_attributes

        item = time("Loaded data bag item #{item_id} from server", :debug) do
          data_bag.item.find(item_id)
        end
        old_attributes = item.attributes.clone

        if diff_data_bag_item(item, item_id, old_attributes, new_attributes, verb,
                              'Chef server version', 'local')
          updated_items << item_id
          unless @dry_run
            override_attributes(item, new_attributes)
            time("Saved data bag item #{item_id} to server", :info) { item.save }
          end
        end
      end

      # Load remaining data bag files.
      list_data_bag_item_files(bag_name).each do |item_path|
        item_id = data_bag_item_id_from_path(item_path)
        next if processed_items.include?(item_id) || ignored_items.include?(item_id)

        processed_items << item_id

        new_attributes = load_data_bag_item_file(bag_name, item_id, :must_exist)
        if @dry_run
          ui.info("Would create data bag item #{item_id} from #{item_path}")
        else
          time("Created data bag item #{item_id} from #{item_path}", :info) do
            data_bag.item.create(new_attributes)
          end
        end
        updated_items << item_id
      end

      unless updated_items.empty?
        ui.info("#{@dry_run ? 'Would update' : 'Updated'} data bag items: " +
                  updated_items.sort.join(', '))
      end
      ui.info("Processed #{processed_items.length} data bag items")
    end

    def get_data_bag_dir(bag_name)
      File::join(get_cookbooks_path, 'data_bags', bag_name)
    end

    def ensure_data_bag_dir_exists(bag_name)
      data_bag_dir = get_data_bag_dir(bag_name)
      unless File.directory?(data_bag_dir)
        fatal_error("#{data_bag_dir} does not exist or is not a directory")
      end
    end

    def load_data_bag_item_file(bag_name, item_id, mode)
      raise unless [:can_skip, :must_exist].include?(mode)

      data_bag_dir = get_data_bag_dir(bag_name)
      item_file_path = File::join(data_bag_dir, item_id + '.json')
      if File.file?(item_file_path)
        contents = open(item_file_path) {|f| JSON.load(f) }
        unless contents['id'] == item_id
          ui.fatal("File #{item_file_path} contains an invalid id (expected #{item_id})")
          raise
        end
        contents
      elsif mode == :can_skip
        ui.warn("Data bag item file #{item_file_path} does not exist, skipping")
        nil
      else
        raise "File #{item_file_path} does not exist"
      end
    end

    def time(description, log_level, &block)
      raise unless [:info, :debug].include?(log_level)
      start_time = Time.now
      result = yield
      msg = "%s in %.3f seconds" % [description, Time.now - start_time]
      if log_level == :info
        ui.info(msg)
      else
        debug(msg)
      end
      result
    end
  end

  class SafeDiffDataBag < DataBagCommand

    include BaseCommandMixin

    banner 'knife safe diff data bag BAG [BAG2]'

    def diff_data_bag_item_files(bag_name1, bag_name2)
      ensure_data_bag_dir_exists(bag_name1)
      ensure_data_bag_dir_exists(bag_name2)

      items_to_compare = {}
      processed_items = Set.new()
      list_data_bag_item_ids(bag_name1).each do |item_id|
        item2 = load_data_bag_item_file(bag_name2, item_id, :can_skip)
        if item2
          item1 = load_data_bag_item_file(bag_name1, item_id, :must_exist)
          processed_items << item_id
          items_to_compare[item_id] = [item1, item2]
        end
      end
      list_data_bag_item_ids(bag_name2).each do |item_id|
        unless processed_items.include?(item_id)
          item1 = load_data_bag_item_file(bag_name1, item_id, :can_skip)
          if item1
            item2 = load_data_bag_item_file(bag_name2, item_id, :must_exist)
            items_to_compare[item_id] = [item1, item2]
          end
        end
      end

      if items_to_compare.empty?
        ui.error("Did not find any data bag items to compare between #{bag_name1} and #{bag_name2}")
        return
      end

      # Find at least one data bag item on the Chef server. This is necessary to be able to
      # decrypt data bags for comparison.
      data_bag1 = ridley.data_bag.find(bag_name1)
      item = nil
      items_to_compare.keys.sort.each do |item_id|
        item = data_bag1.item.find(item_id)
        break if item
      end
      unless item
        fatal_error("Could not find any of the following items in the data bag #{bag_name1}: " +
                    items_to_compare.keys.sort.join(', '))
      end

      items_to_compare.sort.each do |item_id, attributes_pair|
        item.id = item_id
        diff_data_bag_item(item, item_id, *attributes_pair, 'Differences for',
                           "local #{bag_name1}", "local #{bag_name2}")
      end
    end

    def run
      if name_args.size < 1 || name_args.size > 2
        ui.fatal("One or two arguments (data bag names) expected")
        show_usage
        exit(1)
      end

      report_errors do
        if name_args.size == 1
          @dry_run = true
          report_errors { set_data_bag_items(name_args.first) }
        else
          diff_data_bag_item_files(name_args[0], name_args[1])
        end
      end
    end
  end

  class SafeUploadDataBag < DataBagCommand
    include BaseCommandMixin

    banner 'knife safe upload data bag BAG'

    def run
      unless name_args.size == 1
        ui.fatal("Exactly one argument expected")
        show_usage
        exit 1
      end

      report_errors do
        report_errors { set_data_bag_items(name_args.first) }
      end
    end
  end

  class SafeDiffRun_lists < BaseCommand
    include BaseCommandMixin

    banner 'knife safe diff run_lists'
    def run

    end
  end

  class SafeSyncRun_lists < DataBagCommand
    include BaseCommandMixin
    banner 'knife safe upload run_lists'
    def run
    end
  end

end
