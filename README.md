# knife-uploader

## Subcommands

This plugin provides the following Knife subcommands. Specific command options can be found by
invoking the subcommand with a `--help` flag

#### `knife uploader data bag diff DATA_BAG_NAME`

Shows the difference of between the version of the given data bag in the local Chef repository
and the version currently present on the Chef server.

#### `knife uploader data bag diff DATA_BAG_NAME1 DATA_BAG_NAME2`

Shows the difference between two data bags in the local Chef repository.

#### `knife uploader data bag upload DATA_BAG_NAME`

Uploads the given data bag to the Chef server, showing the changes that are being applied. Only
data bag items that have differences are uploaded.

## License and Authors

- Author:: Mikhail Bautin

```text
Copyright 2013 ClearStory Data, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
