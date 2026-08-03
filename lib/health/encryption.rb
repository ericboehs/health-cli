require "open3"

module Health
  # age encryption against an SSH key, mirroring the pattern already proven in
  # ~/Code/github.com/ericboehs/slk. Encrypting to a *key* rather than a
  # passphrase is what keeps `health` non-interactive: reads need the private
  # key on disk, not a prompt.
  class Encryption
    class Error < RuntimeError; end

    SUPPORTED_KEY_TYPES = %w[ssh-rsa ssh-ed25519].freeze

    # Homebrew's bin is not on PATH under launchd, so anything scheduled would
    # fail with a bare `age`. Resolve explicitly and fall back to PATH.
    CANDIDATES = ["/opt/homebrew/bin/age", "/usr/local/bin/age"].freeze

    def self.age_bin
      @age_bin ||= CANDIDATES.find { |p| File.executable?(p) } || "age"
    end

    def available?
      _o, _e, status = Open3.capture3(self.class.age_bin, "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end

    def encrypt(content, ssh_key, output_file)
      require_age!
      pub = public_key_for(ssh_key)

      _o, err, status = Open3.capture3(
        self.class.age_bin, "-R", pub.to_s, "-o", output_file.to_s, stdin_data: content
      )
      raise Error, "age encrypt failed: #{err.strip}" unless status.success?

      File.chmod(0o600, output_file)
      output_file
    end

    def decrypt(encrypted_file, ssh_key)
      return nil unless File.exist?(encrypted_file)

      require_age!
      raise Error, "SSH key not found: #{ssh_key}" unless File.exist?(ssh_key)

      out, err, status = Open3.capture3(
        self.class.age_bin, "-d", "-i", ssh_key.to_s, encrypted_file.to_s
      )
      raise Error, "age decrypt failed for #{encrypted_file}: #{err.strip}" unless status.success?

      out
    end

    # age reads recipients from the *public* key; the private key is only used
    # to decrypt. Validate the type up front — age silently supports only a
    # subset of what ssh-keygen can produce, and an ECDSA key fails at encrypt
    # time with a message that doesn't name the real problem.
    def public_key_for(ssh_key)
      pub = Pathname("#{ssh_key}.pub")
      raise Error, "public key not found: #{pub}" unless pub.exist?

      type = pub.read.split.first
      unless SUPPORTED_KEY_TYPES.include?(type)
        raise Error, "age does not support #{type || "this"} keys; use one of: " \
                     "#{SUPPORTED_KEY_TYPES.join(", ")}"
      end

      pub
    end

    private

    def require_age!
      raise Error, "the `age` encryption tool is not installed (brew install age)" unless available?
    end
  end
end
