# frozen_string_literal: true

module Git
  module LibMonkeyPatch
    # Monkey patch set_custom_git_env_variables due to our ::Git::Error handling.
    #
    # We rescue on the Git::Error and proceed differently based on the output of git.
    # This way makes code language-dependent, so here we ensure that Git gem throw git commands with the "C" language
    def set_custom_git_env_variables
      super
      ENV['LANG'] = 'C.UTF-8'
    end
  end

  class Lib
    prepend LibMonkeyPatch
  end
end
