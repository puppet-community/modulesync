# frozen_string_literal: true

require 'git'

module ModuleSync
  # Wrapper for Git in ModuleSync context
  class Repository
    def initialize(directory:, remote:)
      @directory = directory
      @remote = remote
    end

    def git
      @git ||= Git.open @directory
    end

    # This is an alias to minimize code alteration
    def repo
      git
    end

    def remote_branch_exists?(branch)
      repo.branches.remote.collect(&:name).include?(branch)
    end

    def local_branch_exists?(branch)
      repo.branches.local.collect(&:name).include?(branch)
    end

    def remote_branch_differ?(local_branch, remote_branch)
      !remote_branch_exists?(remote_branch) ||
        repo.diff("#{local_branch}..origin/#{remote_branch}").any?
    end

    def default_branch
      # `Git.default_branch` requires ruby-git >= 1.17.0
      return Git.default_branch(repo.dir) if Git.respond_to? :default_branch

      symbolic_ref = repo.branches.find { |b| b.full.include?('remotes/origin/HEAD') }
      return unless symbolic_ref

      %r{remotes/origin/HEAD\s+->\s+origin/(?<branch>.+?)$}.match(symbolic_ref.full)[:branch]
    end

    def switch(branch:)
      unless branch
        branch = default_branch
        puts "Using repository's default branch: #{branch}"
      end
      return if repo.current_branch == branch

      if local_branch_exists?(branch)
        puts "Switching to branch #{branch}"
        repo.checkout(branch)
      elsif remote_branch_exists?(branch)
        puts "Creating local branch #{branch} from origin/#{branch}"
        repo.checkout("origin/#{branch}")
        repo.branch(branch).checkout
      else
        base_branch = default_branch
        unless base_branch
          puts "Couldn't detect default branch. Falling back to assuming 'master'"
          base_branch = 'master'
        end
        puts "Creating new branch #{branch} from #{base_branch}"
        repo.checkout("origin/#{base_branch}")
        repo.branch(branch).checkout
      end
    end

    def cloned?
      Dir.exist? File.join(@directory, '.git')
    end

    def clone
      puts "Cloning from '#{@remote}'"
      @git = Git.clone(@remote, @directory)
    end

    def prepare_workspace(branch:, operate_offline:)
      if cloned?
        puts "Overriding any local changes to repository in '#{@directory}'"
        git.fetch 'origin', prune: true unless operate_offline
        git.reset_hard
        switch(branch: branch)
        git.pull('origin', branch) if !operate_offline && remote_branch_exists?(branch)
      else
        raise ModuleSync::Error, 'Unable to clone in offline mode.' if operate_offline

        clone
        switch(branch: branch)
      end
    end

    def default_reset_branch(branch)
      remote_branch_exists?(branch) ? branch : default_branch
    end

    def reset_workspace(branch:, operate_offline:, source_branch: nil)
      raise if branch.nil?

      if cloned?
        source_branch ||= "origin/#{default_reset_branch branch}"
        puts "Hard-resetting any local changes to repository in '#{@directory}' from branch '#{source_branch}'"
        switch(branch: branch)
        git.fetch 'origin', prune: true unless operate_offline

        git.reset_hard source_branch
        git.clean(d: true, force: true)
      else
        raise ModuleSync::Error, 'Unable to clone in offline mode.' if operate_offline

        clone
        switch(branch: branch)
      end
    end

    def tag(version, tag_pattern)
      tag = tag_pattern % version
      puts "Tagging with #{tag}"
      repo.add_tag(tag)
      repo.push('origin', tag)
    end

    def checkout_branch(branch)
      selected_branch = branch || repo.current_branch || 'master'
      repo.branch(selected_branch).checkout
      selected_branch
    end

    # Git add/rm, git commit, git push
    def submit_changes(files, options)
      message = options[:message]
      branch = checkout_branch(options[:branch])
      files.each do |file|
        if repo.status.deleted.include?(file)
          repo.remove(file)
        elsif File.exist? File.join(@directory, file)
          repo.add(file)
        end
      end
      begin
        opts_commit = {}
        opts_push = {}
        opts_commit = { amend: true } if options[:amend]
        opts_push = { force: true } if options[:force]
        if options[:pre_commit_script]
          script = "#{File.dirname(File.dirname(__FILE__))}/../contrib/#{options[:pre_commit_script]}"
          `#{script} #{@directory}`
        end
        repo.commit(message, opts_commit)
        if options[:remote_branch]
          if remote_branch_differ?(branch, options[:remote_branch])
            repo.push('origin', "#{branch}:#{options[:remote_branch]}", opts_push)
            puts "Changes have been pushed to: '#{branch}:#{options[:remote_branch]}'"
          end
        else
          repo.push('origin', branch, opts_push)
          puts "Changes have been pushed to: '#{branch}'"
        end
      rescue Git::Error => e
        raise unless e.message.match?(/working (directory|tree) clean/)

        puts "There were no changes in '#{@directory}'. Not committing."
        return false
      end

      true
    end

    def push(branch:, remote_branch:, remote_name: 'origin')
      raise ModuleSync::Error, 'Repository must be locally available before trying to push' unless cloned?

      remote_url = git.remote(remote_name).url
      remote_branch ||= branch
      puts "Push branch '#{branch}' to '#{remote_url}' (#{remote_name}/#{remote_branch})"

      git.push(remote_name, "#{branch}:#{remote_branch}", force: true)
    end

    # Needed because of a bug in the git gem that lists ignored files as
    # untracked under some circumstances
    # https://github.com/schacon/ruby-git/issues/130
    def untracked_unignored_files
      ignore_path = File.join @directory, '.gitignore'
      ignored = File.exist?(ignore_path) ? File.read(ignore_path).split : []
      repo.status.untracked.keep_if { |f, _| ignored.none? { |i| File.fnmatch(i, f) } }
    end

    def show_changes(options)
      checkout_branch(options[:branch])

      $stdout.puts 'Files changed:'
      repo.diff('HEAD', '--').each do |diff|
        $stdout.puts diff.patch
      end

      $stdout.puts 'Files added:'
      untracked_unignored_files.each_key do |file|
        $stdout.puts file
      end

      $stdout.puts "\n\n"
      $stdout.puts '--------------------------------'

      git.diff('HEAD', '--').any? || untracked_unignored_files.any?
    end

    def puts(*args)
      $stdout.puts(*args) if ModuleSync.options[:verbose]
    end
  end
end
