require "./spec_helper"
require "../src/namespace_wrapper"

describe Bootstrap::NamespaceWrapper do
  describe ".unshare_user_and_mount" do
    pending "requires unprivileged user namespaces and writable /proc/self maps" do
      Bootstrap::NamespaceWrapper.unshare_user_and_mount(0, 0)
    end
  end
end
