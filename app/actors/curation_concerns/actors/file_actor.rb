module CurationConcerns
  module Actors
    # actions for a file identified by file_set and relation (maps to use predicate)
    class FileActor
      attr_reader :file_set, :user

      # @param [FileSet] file_set the parent FileSet
      # @param [User] user the user to record as the Agent acting upon the file
      def initialize(file_set, user)
        @file_set = file_set
        @user = user
      end

      # @param [Array<Hash>] file_data The files uploaded by the
      #   user, in hash format: relation => file:
      #   {
      #     original_file: [File, ActionDigest::HTTP::UploadedFile, Tempfile]
      #     restored_file: [File, ActionDigest::HTTP::UploadedFile, Tempfile]
      #   }
      def ingest_file(file_data)
        IngestFileJob.perform_later(
          how_to_attach(file_set, file_data, user)
        )
        true
      end

      def how_to_attach(file_set, file_data, user)
        file_data.map do |relation, file|
          {
            file_set: file_set,
            user: user,
            working_file: working_file(file),
            options: ingest_options(file, relation)
          }
        end
      end

      def revert_to(relation, revision_id)
        repository_file = file_set.send(relation.to_sym)
        repository_file.restore_version(revision_id)

        return false unless file_set.save

        CurationConcerns::VersioningService.create(repository_file, user)

        # Characterize the original file from the repository
        CharacterizeJob.perform_later(file_set, repository_file.id)
        true
      end

      private

        def working_file(file)
          path = file.path
          return path if File.exist?(path)
          CurationConcerns::WorkingDirectory.copy_file_to_working_directory(file, file_set.id)
        end

        # @param [Array<File, ActionDigest::HTTP::UploadedFile, Tempfile>]
        #   files to attach to the FileSet
        def ingest_options(file, relation, opts = {})
          opts[:mime_type] = file.content_type if file.respond_to?(:content_type)
          opts[:filename] = file.original_filename if file.respond_to?(:original_filename)
          opts.merge(relation: relation.to_s)
        end
    end
  end
end
