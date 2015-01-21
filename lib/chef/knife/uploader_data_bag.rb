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

require 'chef/knife/uploader_base'

module KnifeUploader

  module DataBagUtils
    class << self
      def decrypted_attributes(data_bag_item)
        begin
          [
            Hash[data_bag_item.attributes.map do
              |key, value| [key, key == "id" ? value : data_bag_item.decrypt_value(value)]
            end],
            true  # decryption successful
          ]
        rescue OpenSSL::Cipher::CipherError, NoMethodError, NotImplementedError, ArgumentError => ex
          [data_bag_item.attributes.clone, false]
        end
      end
    end
  end

  class UploaderDataBagCommand < BaseCommand

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
        ui.info("#{item_id} has no differences (no decryption attempted)\n\n")
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
        ui.info("#{item_id} has differences before decryption " +
                "but no differences after decryption\n\n")
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
      if data_bag.nil?
        if @dry_run
          ui.warn("Data bag #{bag_name} does not exist on the Chef server, skipping")
          return
        else
          ui.info("Data bag #{bag_name} does not exist on the Chef server, creating")
          ridley.data_bag.create(:name => bag_name)
          data_bag = ridley.data_bag.find(bag_name)
        end
      end

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
          ui.info("Would create data bag item #{item_id} from #{item_path}\n\n")
        else
          time("Created data bag item #{item_id} from #{item_path}", :info) do
            data_bag.item.create(new_attributes)
          end
        end
        updated_items << item_id
      end

      unless updated_items.empty?
        ui.info("#{@dry_run ? 'Would update' : 'Updated'} data bag items: " +
                  updated_items.sort.join(', ') + "\n\n")
      end
      ui.info("Processed #{processed_items.length} data bag items")
    end

    def get_data_bag_dir(bag_name)
      File.join(
        parsed_knife_config.get_data_bag_path || File::join(get_chef_repo_path, 'data_bags'),
        bag_name
      )
    end

    def ensure_data_bag_dir_exists(bag_name)
      data_bag_dir = get_data_bag_dir(bag_name)
      unless File.directory?(data_bag_dir)
        raise "#{data_bag_dir} does not exist or is not a directory"
      end
    end

    def load_data_bag_item_file(bag_name, item_id, mode)
      raise unless [:can_skip, :must_exist].include?(mode)

      data_bag_dir = get_data_bag_dir(bag_name)
      item_file_path = File::join(data_bag_dir, item_id + '.json')
      if File.file?(item_file_path)
        contents = open(item_file_path) {|f| JSON.load(f) }
        unless contents['id'] == item_id
          raise "File #{item_file_path} contains an invalid id (expected #{item_id})"
        end
        contents
      elsif mode == :can_skip
        ui.warn("Data bag item file #{item_file_path} does not exist, skipping\n\n")
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

  class UploaderDataBagDiff < UploaderDataBagCommand

    include BaseCommandMixin

    # TODO: can this be moved to a module shared between data bag upload and diff commands?
    option :secret_file,
      long: "--secret-file SECRET_FILE",
      description: 'A file containing the secret key to use to encrypt data bag item values'

    banner 'knife uploader data bag diff BAG [BAG2]'

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

    def run_internal
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

  class UploaderDataBagUpload < UploaderDataBagCommand
    include BaseCommandMixin

    # TODO: can this be moved to a module shared between data bag upload and diff commands?
    option :secret_file,
      long: "--secret-file SECRET_FILE",
      description: 'A file containing the secret key to use to encrypt data bag item values'

    banner 'knife uploader data bag upload BAG'

    def run_internal
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

end
