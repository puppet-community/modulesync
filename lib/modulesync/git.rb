require 'git'
require 'puppet_blacksmith'

module ModuleSync
  module Git
    include Constants

    def self.remote_branch_exists?(repo, branch)
      repo.branches.remote.collect(&:name).include?(branch)
    end

    def self.local_branch_exists?(repo, branch)
      repo.branches.local.collect(&:name).include?(branch)
    end

    def self.switch_branch(repo, branch)
      unless repo.branch.name == branch
        if local_branch_exists?(repo, branch)
          puts "Switching to branch #{branch}"
          repo.checkout(branch)
        elsif remote_branch_exists?(repo, branch)
          puts "Creating local branch #{branch} from origin/#{branch}"
          repo.checkout("origin/#{branch}")
          repo.branch(branch).checkout
        else
          repo.checkout('origin/master')
          puts "Creating new branch #{branch}"
          repo.branch(branch).checkout
        end
      end
    end

    def self.pull(git_base, name, branch, project_root, opts)
      Dir.mkdir(project_root) unless Dir.exist?(project_root)

      # Repo needs to be cloned in the cwd
      if !Dir.exist?("#{project_root}/#{name}") || !Dir.exist?("#{project_root}/#{name}/.git")
        puts 'Cloning repository fresh'
        remote = opts[:remote] || (git_base.start_with?('file://') ? "#{git_base}/#{name}" : "#{git_base}/#{name}.git")
        local = "#{project_root}/#{name}"
        puts "Cloning from #{remote}"
        repo = ::Git.clone(remote, local)
        switch_branch(repo, branch)
      # Repo already cloned, check out master and override local changes
      else
        # Some versions of git can't properly handle managing a repo from outside the repo directory
        Dir.chdir("#{project_root}/#{name}") do
          puts "Overriding any local changes to repositories in #{project_root}"
          repo = ::Git.open('.')
          repo.fetch
          repo.reset_hard
          switch_branch(repo, branch)
          repo.pull('origin', branch) if remote_branch_exists?(repo, branch)
        end
      end
    end

    def self.update_changelog(repo, version, message, module_root)
      changelog = "#{module_root}/CHANGELOG.md"
      if File.exist?(changelog)
        puts "Updating #{changelog} for version #{version}"
        changes = File.readlines(changelog)
        File.open(changelog, 'w') do |f|
          date = Time.now.strftime('%Y-%m-%d')
          f.puts "## #{date} - Release #{version}\n\n"
          f.puts "#{message}\n\n"
          # Add old lines again
          f.puts changes
        end
        repo.add('CHANGELOG.md')
      else
        puts 'No CHANGELOG.md file found, not updating.'
      end
    end

    def self.bump(repo, m, message, module_root, changelog = false)
      new = m.bump!
      puts "Bumped to version #{new}"
      repo.add('metadata.json')
      update_changelog(repo, new, message, module_root) if changelog
      repo.commit("Release version #{new}")
      repo.push
      new
    end

    def self.tag(repo, version, tag_pattern)
      tag = tag_pattern % version
      puts "Tagging with #{tag}"
      repo.add_tag(tag)
      repo.push('origin', tag)
    end

    # Git add/rm, git commit, git push
    def self.update(name, files, options)
      module_root = "#{options[:project_root]}/#{name}"
      message = options[:message]
      branch = if options[:remote_branch]
                 "#{options[:branch]}:#{options[:remote_branch]}"
               else
                 options[:branch]
               end
      repo = ::Git.open(module_root)
      repo.branch(options[:branch]).checkout
      files.each do |file|
        if repo.status.deleted.include?(file)
          repo.remove(file)
        else
          repo.add(file)
        end
      end
      begin
        opts_commit = {}
        opts_push = {}
        opts_commit = { :amend => true } if options[:amend]
        opts_push = { :force => true } if options[:force]
        if options[:pre_commit_script]
          script = "#{File.dirname(File.dirname(__FILE__))}/../contrib/#{options[:pre_commit_script]}"
          `#{script} #{module_root}`
        end
        repo.commit(message, opts_commit)
        repo.push('origin', branch, opts_push)
        # Only bump/tag if pushing didn't fail (i.e. there were changes)
        m = Blacksmith::Modulefile.new("#{module_root}/metadata.json")
        if options[:bump]
          new = bump(repo, m, message, module_root, options[:changelog])
          tag(repo, new, options[:tag_pattern]) if options[:tag]
        end
      rescue ::Git::GitExecuteError => git_error
        if git_error.message.include? 'nothing to commit, working directory clean'
          puts "There were no files to update in #{name}. Not committing."
        else
          puts git_error
          exit
        end
      end
    end

    # Needed because of a bug in the git gem that lists ignored files as
    # untracked under some circumstances
    # https://github.com/schacon/ruby-git/issues/130
    def self.untracked_unignored_files(repo)
      ignore_path = "#{repo.dir.path}/.gitignore"
      ignored = if File.exist?(ignore_path)
                  File.open(ignore_path).read.split
                else
                  []
                end
      repo.status.untracked.keep_if { |f, _| !ignored.any? { |i| File.fnmatch(i, f) } }
    end

    def self.update_noop(name, options)
      puts "Using no-op. Files in #{name} may be changed but will not be committed."

      repo = ::Git.open("#{options[:project_root]}/#{name}")
      repo.branch(options[:branch]).checkout

      puts 'Files changed: '
      repo.diff('HEAD', '--').each do |diff|
        puts diff.patch
      end

      puts 'Files added: '
      untracked_unignored_files(repo).each do |file, _|
        puts file
      end

      puts "\n\n"
      puts '--------------------------------'
    end
  end
end
