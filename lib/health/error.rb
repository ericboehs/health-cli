module Health
  # One ancestor for everything this tool raises on purpose.
  #
  # The point is the top-level rescue in CLI#run. Listing each error class there
  # by hand meant that adding a new one — or moving an existing one, as
  # Session::NotAuthenticated showed — silently turned a message the operator
  # was meant to read into a Ruby backtrace. A backtrace is worse than unhelpful
  # here: the frames carry `person_id` and URLs from a medical record.
  #
  # So: raise a Health::Error and it is reported as an error. Raise anything
  # else and it is a bug, which is what a backtrace should mean.
  class Error < RuntimeError; end
end
