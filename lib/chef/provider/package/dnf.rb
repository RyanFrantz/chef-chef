#
# Copyright:: Copyright 2016, Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/provider/package"
require "chef/resource/dnf_package"
require "chef/mixin/which"
require "chef/mixin/get_source_from_package"
require "chef/provider/package/dnf/python_helper"
require "chef/provider/package/dnf/version"

class Chef
  class Provider
    class Package
      class Dnf < Chef::Provider::Package
        extend Chef::Mixin::Which
        include Chef::Mixin::GetSourceFromPackage

        allow_nils
        use_multipackage_api
        use_package_name_for_source

        provides :package, platform_family: %w{rhel fedora} do
          which("dnf")
        end

        provides :dnf_package, os: "linux"

        #
        # Most of the magic in this class happens in the python helper script.  The ruby side of this
        # provider knows only enough to translate Chef-style new_resource name+package+version into
        # a request to the python side.  The python side is then responsible for knowing everything
        # about RPMs and what is installed and what is available.  The ruby side of this class should
        # remain a lightweight translation layer to translate Chef requests into RPC requests to
        # python.  This class knows nothing about how to compare RPM versions, and does not maintain
        # any cached state of installed/available versions and should be kept that way.
        #
        def python_helper
          @python_helper ||= PythonHelper.instance
        end

        def load_current_resource
          flushcache if new_resource.flush_cache[:before]

          @current_resource = Chef::Resource::DnfPackage.new(new_resource.name)
          current_resource.package_name(new_resource.package_name)
          current_resource.version(get_current_versions)

          current_resource
        end

        def define_resource_requirements
          # FIXME:
          #unless ::File.exist?(new_resource.source)
          #  raise Chef::Exceptions::Package, "Package #{new_resource.name} not found: #{new_resource.source}"
          #end
          super
        end

        def candidate_version
          package_name_array.each_with_index.map do |pkg, i|
            available_version(i).version_with_arch
          end
        end

        def get_current_versions
          package_name_array.each_with_index.map do |pkg, i|
            installed_version(i).version_with_arch
          end
        end

        def install_package(names, versions)
          if new_resource.source
            dnf(new_resource.options, "-y install", new_resource.source)
          else
            resolved_names = names.each_with_index.map { |name, i| available_version(i).to_s unless name.nil? }
            dnf(new_resource.options, "-y install", resolved_names)
          end
          flushcache_after
        end

        # dnf upgrade does not work on uninstalled packaged, while install will upgrade
        alias_method :upgrade_package, :install_package

        def remove_package(names, versions)
          resolved_names = names.each_with_index.map { |name, i| installed_version(i).to_s unless name.nil? }
          dnf(new_resource.options, "-y remove", resolved_names)
          flushcache_after
        end

        alias_method :purge_package, :remove_package

        action :flush_cache do
          python_helper.flushcache
        end

        private

        def flushcache_after
          if new_resource.flush_cache[:after]
            flushcache
          else
            flushcache_installed
          end
        end

        def resolve_source_to_version_obj
          shell_out_with_timeout!("rpm -qp --queryformat '%{NAME} %{EPOCH} %{VERSION} %{RELEASE} %{ARCH}\n' #{new_resource.source}").stdout.each_line do |line|
            case line
            when /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/
              return Version.new($1, "#{$2 == "(none)" ? "0" : $2}:#{$3}-#{$4}", $5)
            end
          end
        end

        # @returns Array<Version>
        def available_version(index)
          @available_version ||= []

          if new_resource.source
            @available_version[index] ||= resolve_source_to_version_obj
          else
            @available_version[index] ||= python_helper.query(:whatavailable, package_name_array[index], safe_version_array[index], safe_arch_array[index])
          end

          @available_version[index]
        end

        # @returns Array<Version>
        def installed_version(index)
          @installed_version ||= []
          if new_resource.source
            @installed_version[index] ||= python_helper.query(:whatinstalled, available_version(index).name, safe_version_array[index], safe_arch_array[index])
          else
            @installed_version[index] ||= python_helper.query(:whatinstalled, package_name_array[index], safe_version_array[index], safe_arch_array[index])
          end
          @installed_version[index]
        end

        def flushcache
          python_helper.flushcache
        end

        def flushcache_installed
          python_helper.flushcache_installed
        end

        def dnf(*args)
          shell_out_with_timeout!(a_to_s("dnf", *args))
        end

        def safe_version_array
          if new_resource.version.is_a?(Array)
            new_resource.version
          elsif new_resource.version.nil?
            package_name_array.map { nil }
          else
            [ new_resource.version ]
          end
        end

        def safe_arch_array
          if new_resource.arch.is_a?(Array)
            new_resource.arch
          elsif new_resource.arch.nil?
            package_name_array.map { nil }
          else
            [ new_resource.arch ]
          end
        end

      end
    end
  end
end
