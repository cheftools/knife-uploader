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

  class UploaderRunListCommand < BaseCommand

    def filtered_chef_nodes
      ridley.node.all.sort_by {|node| node.name }.to_enum
                     .lazy_select {|node| node.name =~ @pattern }
                     .lazy_map {|node| ridley.node.find(node.name) }
                     .lazy_select {|node| node.chef_environment == @env_name }
    end

    def set_run_lists
      run_lists_file_path = File::join(get_chef_repo_path, 'run_lists', "#{@env_name}.json")
      target_run_lists = File.open(run_lists_file_path) {|f| JSON.load(f) }

      filtered_chef_nodes.each do |node|

        debug("Comparing run lists for node #{node.name}")
        old_run_list = node.run_list
        new_run_list = []

        # Concatenate all matching patterns. This allows to specify some common parts of run lists
        # only once.
        target_run_lists.each do |pattern, run_list|
          if node.name =~ /\A#{pattern}\Z/
            new_run_list += run_list
          end
        end
        debug("New run list for node #{node.name}: #{new_run_list}")

        unless new_run_list
          ui.warn("No new run list defined for node #{node.name}, skipping")
          next
        end

        ui.info((@dry_run ? 'Would modify' : 'Modifying') +
                " the run list for node #{node.name}:\n" +
                diff_color(old_run_list.join("\n") + "\n",
                           new_run_list.join("\n") + "\n"))

        unless @dry_run
          node.run_list = new_run_list
          node.save
        end
      end

      ui.info("Finished #{@dry_run ? 'showing differences for' : 'setting'} run lists in " +
              "environment #{@env_name}")
    end

    def validate_arguments
      if name_args.size != 1
        ui.fatal("Exactly one argument expected: environment")
        show_usage
        exit(1)
      end

      @env_name = name_args[0]
    end

  end

  class UploaderRunListDiff < UploaderRunListCommand

    include BaseCommandMixin

    banner 'knife uploader run list diff ENVIRONMENT'

    def run_internal
      validate_arguments
      @dry_run = true
      set_run_lists
    end

  end

  class UploaderRunListUpload < UploaderRunListCommand

    include BaseCommandMixin

    banner 'knife uploader run list upload ENVIRONMENT'

    def run_internal
      validate_arguments
      set_run_lists
    end
  end

end
