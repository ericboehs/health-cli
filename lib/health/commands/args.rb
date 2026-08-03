module Health
  module Commands
    module Args
      # Usage errors exit 2, distinct from a runtime failure's 1.
      class BadArgument < RuntimeError; end
    end
  end
end
