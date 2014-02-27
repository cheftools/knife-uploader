# Copyright (C) 2013 ClearStory Data, Inc.
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$:.push File.expand_path("../lib", __FILE__)
require "knife-uploader/version"

Gem::Specification.new do |spec|
  spec.name          = 'knife-uploader'
  spec.version       = Knife::Uploader::VERSION
  spec.authors       = ['Mikhail Bautin']
  spec.email         = ['mbautin@gmail.com']
  spec.description   = 'Knife plugin for better uploading of data bags, run lists, etc.'
  spec.summary       = spec.description
  spec.homepage      = 'https://github.com/mbautin/knife-uploader'
  spec.license       = 'Apache'
  spec.files         = Dir.glob("{bin,lib}/**/*") + %w(Gemfile)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']
  spec.add_dependency 'chef', '~> 11.4'
  spec.add_dependency 'diffy', '~> 3.0'
  spec.add_dependency 'hashie', '~> 2.0'
  spec.add_dependency 'ridley', '~> 1.5.3'
  spec.add_dependency 'varia_model', '~> 0.2.0'
  spec.add_dependency 'celluloid', '~> 0.14.1'
  spec.add_dependency 'faraday', '~> 0.8.9'
end
