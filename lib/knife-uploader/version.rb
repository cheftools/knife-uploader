module Knife
  module Uploader
    VERSION = IO.read(File.expand_path("../../../VERSION", __FILE__))
    MAJOR, MINOR, TINY = VERSION.split('.')
  end
end
