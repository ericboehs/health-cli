require "health/commands/resource"

module Health
  module Commands
    # `health docs` — clinical notes and visit summaries, from
    # DocumentReference, and `--get` to download one.
    #
    # This is the only command that writes a file. Everything else here prints
    # and forgets; a visit summary is a PDF of a medical record, so it is
    # downloaded only when asked for by id, only to a path the operator can see
    # in the output, and never as a side effect of listing.
    class Docs < Resource
      def resource_type = "DocumentReference"
      def noun = "documents"

      # A content type is a poor column — "application/pdf" is nine characters
      # of prefix and three of information.
      EXTENSIONS = {
        "application/pdf" => "pdf",
        "text/html" => "html",
        "application/xhtml+xml" => "html",
        "text/plain" => "txt",
        "text/rtf" => "rtf",
        "application/xml" => "xml"
      }.freeze

      def columns
        [
          [:title, "Document", { max: 44 }],
          [:kind, "Kind"],
          [:author, "Author", { max: 22 }],
          [:format, "Format"],
          [:id, "ID"],
          [:date, "Date"]
        ]
      end

      def run(argv)
        opts = parse!(argv.dup)
        opts[:get] ? download(opts) : execute(opts)
      end

      def extract(resource)
        attachment = attachment_of(resource)

        {
          title: FHIR.presence(attachment["title"]) || FHIR.display(resource["type"]),
          kind: FHIR.display(Array(resource["category"]).first),
          author: Array(resource["author"]).first&.dig("display"),
          format: EXTENSIONS.fetch(attachment["contentType"].to_s, FHIR.presence(attachment["contentType"])),
          content_type: FHIR.presence(attachment["contentType"]),
          url: FHIR.presence(attachment["url"]),
          custodian: resource.dig("custodian", "display"),
          status: FHIR.presence(resource["docStatus"]) || FHIR.presence(resource["status"]),
          date: FHIR.date_from(resource, "date"),
          id: resource["id"]
        }
      end

      private

      # A DocumentReference may carry the same note in several renderings. PDF
      # is preferred because it is the one Millennium always produces and the
      # one that opens without a browser; failing that, the first attachment
      # that has a URL at all.
      def attachment_of(resource)
        attachments = Array(resource["content"]).filter_map do |c|
          c["attachment"] if c.is_a?(Hash) && c["attachment"].is_a?(Hash)
        end
        attachments.find { |a| a["contentType"] == "application/pdf" } || attachments.first || {}
      end

      # `--get` re-lists to find the document rather than reading
      # `DocumentReference/{id}` directly, because the id the operator has is
      # the one this command printed, and matching against that list is what
      # makes "no document with that id" a usable message instead of a 404.
      def download(opts)
        @opts = opts
        wanted = opts[:get]
        item = client.search(resource_type).map { |r| extract(r) }.find { |i| i[:id].to_s == wanted }

        raise Args::BadArgument, "no document with id #{wanted.inspect} — run `health docs` for the list" if item.nil?
        raise Health::Error, "document #{wanted} has no downloadable attachment" if item[:url].nil?

        content_type, body = client.fetch_binary(item[:url], accept: item[:content_type])
        path = destination(opts, item, content_type)
        write!(path, body)

        @err.puts "Saved #{item[:title]} (#{body.bytesize} bytes) to #{path}" unless @global.quiet
        0
      end

      def destination(opts, item, content_type)
        return File.expand_path(opts[:out]) if opts[:out]

        extension = EXTENSIONS.fetch(content_type, "bin")
        File.expand_path("#{slug(item[:title])}-#{item[:date] || item[:id]}.#{extension}", Dir.pwd)
      end

      # Titles come from the record and contain spaces, asterisks ("General
      # Exam *") and slashes, none of which belong in a filename produced
      # without being asked.
      def slug(title)
        cleaned = title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        cleaned.empty? ? "document" : cleaned
      end

      # Refuses to overwrite. A downloaded record is not something to replace
      # silently, and two visits on one day would otherwise collide on the
      # derived name.
      #
      # Opened with EXCL and 0o600 rather than checked-then-written: the check
      # and the write are one operation that way, and the file is a medical
      # record, which has no business being world-readable merely because it
      # landed in a directory whose umask says so. Every other file this tool
      # writes is 0o600 already.
      def write!(path, body)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(body)
        end
      rescue Errno::EEXIST
        raise Health::Error, "#{path} already exists — pass --out to choose another name"
      end

      def consume(arg, argv, opts)
        case arg
        when "--get" then opts[:get] = value!(argv.shift, arg)
        when "--out" then opts[:out] = value!(argv.shift, arg)
        else super
        end
      end
    end
  end
end
