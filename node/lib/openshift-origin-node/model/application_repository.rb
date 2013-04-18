#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++
require 'rubygems'
require 'erb'
require 'openshift-origin-common'
require 'openshift-origin-node/utils/shell_exec'
require 'openshift-origin-node/utils/selinux'
require 'openshift-origin-node/utils/environ'
require 'openshift-origin-common/utils/path_utils'
require 'openshift-origin-node/utils/node_logger'

module OpenShift

  ##
  # This class represents an Application's Git repository

  class ApplicationRepository
    include OpenShift::Utils
    include NodeLogger

    SUPPORTED_PROTOCOLS = %w{git:// http:// https:// file:// ftp:// ftps:// rsync://}

    attr_reader :path

    ##
    # Creates a new application Git repository from a template
    #
    # +user+ is of type +UnixUser+
    def initialize(container)
      @container = container
      @path = PathUtils.join(@container.container_dir, 'git', "#{@container.application_name}.git")
    end

    def exist?
      File.directory?(@path)
    end

    alias exists? exist?

    ##
    # +populate_from_cartridge+ uses the provided +cartridge_name+ to install a template application
    # for the gear
    #
    # Template search locations:
    #   * ~/<cartridge home>/template
    #   * ~/<cartridge home>/template.git
    #   * ~/<cartridge home>/usr/template
    #   * ~/<cartridge home>/usr/template.git
    #
    # return nil if application bare repository exists or no template found
    #            otherwise path of template used
    def populate_from_cartridge(cartridge_name)
      return nil if exists?

      FileUtils.mkpath(File.join(@container.container_dir, 'git'))

      locations = [
          File.join(@container.container_dir, cartridge_name, 'template'),
          File.join(@container.container_dir, cartridge_name, 'template.git'),
          File.join(@container.container_dir, cartridge_name, 'usr', 'template'),
          File.join(@container.container_dir, cartridge_name, 'usr', 'template.git'),
      ]

      template = locations.find {|l| File.directory?(l)}
      logger.debug("Using '#{template}' to populate git repository for #{@container.uuid}")
      return nil unless template

      # expose variables for ERB processing
      @application_name = @container.application_name
      @cartridge_name   = cartridge_name
      @user_homedir     = @container.container_dir

      if template.end_with? '.git'
        FileUtils.cp_r(template, @path, preserve: true)
      else
        build_bare(template)
      end

      configure
      template
    end

    ##
    # +populate_from_url+ uses the provided +cartridge_url+ to install a template application
    # for the gear
    #
    def populate_from_url(cartridge_name, url)
      return nil if exists?

      supported = SUPPORTED_PROTOCOLS.any? { |k| url.start_with?(k) }
      raise Utils::ShellExecutionException.new(
                "CLIENT_ERROR: Source Code repository URL type must be one of: #{SUPPORTED_PROTOCOLS.join(', ')}", 130
            ) unless supported

      git_path = File.join(@container.container_dir, 'git')
      FileUtils.mkpath(git_path)

      # expose variables for ERB processing
      @application_name = @container.application_name
      @cartridge_name   = cartridge_name
      @user_homedir     = @container.container_dir
      @url              = url

      begin
        @container.run_in_root_context(ERB.new(GIT_URL_CLONE).result(binding),
                       chdir:               git_path,
                       expected_exitstatus: 0)
      rescue Utils::ShellExecutionException => e
        raise Utils::ShellExecutionException.new(
                  "CLIENT_ERROR: Source Code repository could not be cloned: '#{url}'.  Please verify the repository is correct and contact support.",
                  131
              )
      end

      configure
    end

    def deploy
      # expose variables for ERB processing
      @application_name = @container.application_name
      @user_homedir     = @container.container_dir
      @target_dir       = PathUtils.join(@container.container_dir, 'app-root', 'runtime', 'repo')

      FileUtils.rm_rf Dir.glob(PathUtils.join(@target_dir, '*'))
      FileUtils.rm_rf Dir.glob(PathUtils.join(@target_dir, '.[^\.]*'))

      @container.run_in_container_context(ERB.new(GIT_DEPLOY).result(binding),
                     chdir:               @path,
                     expected_exitstatus: 0)

      return unless File.exist? PathUtils.join(@target_dir, '.gitmodules')

      env = Utils::Environ.load(PathUtils.join(@container.container_dir, '.env'))

      cache = PathUtils.join(env['OPENSHIFT_TMP_DIR'], 'git_cache')
      FileUtils.rm_r(cache) if File.exist?(cache)
      FileUtils.mkpath(cache)

      @container.run_in_container_context(ERB.new(GIT_DEPLOY_SUBMODULES).result(binding),
                     chdir:               @container.container_dir,
                     env:                 env,
                     expected_exitstatus: 0)

      @container.run_in_container_context("/bin/rm -rf #{cache} &")
    end

    def destroy
      FileUtils.rm_r(@path) if File.exist? @path
    end

    ##
    # Install Git repository hooks and set permissions
    def configure
      @container.set_rw_permission_R(@path)

      # application developer cannot change git hooks
      hooks = File.join(@path, 'hooks')
      FileUtils.chown_R(0, 0, hooks)

      render_file = lambda { |f, m, t|
        File.open(f, 'w', m) { |f| f.write(ERB.new(t).result(binding)) }
      }

      render_file.call(File.join(@path, 'description'), 0644, GIT_DESCRIPTION)
      render_file.call(File.join(@container.container_dir, '.gitconfig'), 0644, GIT_CONFIG)

      render_file.call(File.join(hooks, 'pre-receive'), 0755, PRE_RECEIVE)
      render_file.call(File.join(hooks, 'post-receive'), 0755, POST_RECEIVE)
    end

    ##
    # Copy a file tree structure and build an application repository
    def build_bare(path)
      template = File.join(@container.container_dir, 'git', 'template')
      FileUtils.rm_r(template) if File.exist? template

      git_path = File.join(@container.container_dir, 'git')
      @container.run_in_root_context("/bin/cp -ad #{path} #{git_path}", expected_exitstatus: 0)

      @container.run_in_root_context(ERB.new(GIT_INIT).result(binding),
                     chdir:               template,
                     expected_exitstatus: 0)
      begin
        # trying to clone as the user proved to be painful as git managed to "lose" the selinux context
        @container.run_in_root_context(ERB.new(GIT_LOCAL_CLONE).result(binding),
                       chdir:               git_path,
                       expected_exitstatus: 0)
      rescue ShellExecutionException => e
        FileUtils.rm_r(@path) if File.exist? @path

        raise ShellExecutionException.new(
                  'Failed to clone application git repository from template repository',
                  e.rc, e.stdout, e.stderr)
      ensure
        FileUtils.rm_r(template)
      end
    end

    private
    #-- ERB Templates -----------------------------------------------------------

    GIT_INIT = %Q{\
set -xe;
git init;
git config user.email "builder@example.com";
git config user.name "Template builder";
git add -f .;
git commit -a -m "Creating template"
}

    GIT_LOCAL_CLONE = %Q{\
set -xe;
git clone --bare --no-hardlinks template <%= @application_name %>.git;
GIT_DIR=./<%= @application_name %>.git git repack
}

    GIT_URL_CLONE = %Q{\
set -xe;
git clone --bare --no-hardlinks <%= @url %> <%= @application_name %>.git;
GIT_DIR=./<%= @application_name %>.git git repack
}

    GIT_DEPLOY = %Q{\
set -xe;
shopt -s dotglob;
rm -rf <%= @target_dir %>/*;
git archive --format=tar HEAD | (cd <%= @target_dir %> && tar --warning=no-timestamp -xf -);
}

    GIT_DEPLOY_SUBMODULES = %Q{\
set -xe;
cd $OPENSHIFT_TMP_DIR;
git clone <%= @path %> git_cache;
pushd git_cache;
git submodule update --init --recursive;
git submodule foreach --recursive 'git archive --format=tar HEAD | (cd <%= @target_dir %>/\\\\\\$path && tar --warning=no-timestamp -xf -)';
popd;
}

    GIT_DESCRIPTION = %Q{
<%= @cartridge_name %> application <%= @application_name %>
}

    GIT_CONFIG = %Q{\
[user]
  name = OpenShift System User
[gc]
  auto = 100
}

    PRE_RECEIVE = %Q{\
gear prereceive
}

    POST_RECEIVE = %Q{\
gear postreceive
}
  end
end
