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
require 'hashie'
require 'logger'
require 'celluloid'
require 'varia_model'

# "Lazy select" from http://www.michaelharrison.ws/weblog/?p=163
class Enumerator
  def lazy_select(&block)
    Enumerator.new do |yielder|
      self.each do |val|
        yielder.yield(val) if block.call(val)
      end
    end
  end

  def lazy_map(&block)
    Enumerator.new do |yielder|
      self.each do |val|
        yielder.yield(block.call(val))
      end
    end
  end
end

module KnifeUploader

  class KnifeConfigParser
    attr_reader :knife

    def initialize(knife_conf_path)
      @knife = {}
      instance_eval(IO.read(knife_conf_path), knife_conf_path)
    end

    def cookbook_path(path_list)
      @cookbook_path_list = path_list
    end

    def get_cookbook_path_list
      @cookbook_path_list
    end

    def data_bag_path(path)
      @data_bag_path = path
    end

    def get_data_bag_path
      @data_bag_path
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

  module BaseCommandMixin
    def self.included(includer)
      includer.class_eval do
        deps do
          require 'ridley'
          Celluloid.logger.level = Logger::ERROR
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
        @pattern = //  # matches anything
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

    def locate_config_value(key, kind = :optional)
      raise unless [:required, :optional].include?(kind)
      key = key.to_sym
      value = config[key] || Chef::Config[:knife][key]
      if kind == :required && value.nil?
        raise "#{key} not specified"
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

    def get_chef_repo_path
      unless @chef_repo_path
        path_list = parsed_knife_config.get_cookbook_path_list
        path_list.each do |cookbooks_path|
          [cookbooks_path, File.expand_path('..', cookbooks_path)].each do |path|
            if ['.git', 'data_bags', 'environments', 'roles'].map do |subdir_name|
              File.directory?(File.join(path, subdir_name))
            end.all?
              @chef_repo_path = path
            end
          end
        end

        raise "No chef repository checkout path could be determined using " +
              "cookbook paths #{path_list}" unless @chef_repo_path

        debug("Identified Chef repo path: #{@chef_repo_path}")
      end

      @chef_repo_path
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

    def run
      begin
        run_internal
      ensure
        # Cleanup code can be added here.
      end
    end
  end

end
