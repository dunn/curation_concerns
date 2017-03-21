class IngestFileJob < ActiveJob::Base
  queue_as CurationConcerns.config.ingest_queue_name

  # @param [Array<Hash>] file_data The information about what files to
  #   attach to what FileSets, in hashes:
  #   {
  #     file_set: [FileSet],
  #     user: [User],
  #     working_file: [String],
  #     options: [Hash],
  #   }
  def perform(file_data)
    file_data.each do |blob|
      ingest!(blob[:file_set], blob[:working_file], blob[:options])

      repository_file = blob[:file_set].send(
        blob[:options].fetch(:relation, :original_file).to_sym
      )

      filename = CurationConcerns::WorkingDirectory.find_or_retrieve(
        repository_file.id, blob[:file_set].id
      )

      CurationConcerns::VersioningService.create(repository_file, blob[:user])

      characterize!(blob[:file_set], filename)
      derive!(blob[:file_set], filename)

      FileUtils.rm_f filename
    end
  end

  # @param [FileSet] file_set
  # @param [String] filepath the cached file within the CurationConcerns.config.working_path
  # @option opts [String] mime_type
  # @option opts [String] filename
  # @option opts [String] relation, ex. :original_file
  def ingest!(file_set, filepath, opts)
    # Wrap in an IO decorator to attach passed-in options
    local_file = Hydra::Derivatives::IoDecorator.new(File.open(filepath, "rb"))
    local_file.mime_type = opts.fetch(:mime_type, nil)
    local_file.original_name = opts.fetch(:filename, File.basename(filepath))

    # Tell AddFileToFileSet service to skip versioning because versions will be minted by
    # VersionCommitter when necessary during save_characterize_and_record_committer.
    Hydra::Works::AddFileToFileSet.call(file_set,
                                        local_file,
                                        opts.fetch(:relation, :original_file).to_sym,
                                        versioning: false)
    # Persist changes to the file_set
    file_set.save!
  end

  # From /curation_concerns-1.6.3/app/jobs/characterize_job.rb
  # @param [FileSet] file_set
  # @param [String] filename the path to the original file
  def characterize!(file_set, filename)
    Hydra::Works::CharacterizationService.run(file_set.original_file, filename)
    file_set.save!
    file_set.update_index
    file_set.parent.in_collections.each(&:update_index) if file_set.parent
  end

  # @param [FileSet] file_set
  # @param [String] filename the path to the original file
  def derive!(file_set, filename)
    return if file_set.video? && !CurationConcerns.config.enable_ffmpeg

    file_set.create_derivatives(filename)

    # Reload from Fedora and reindex for thumbnail and extracted text
    file_set.reload
    file_set.update_index
    file_set.parent.update_index if parent_needs_reindex?(file_set)
  end

  # If this file_set is the thumbnail for the parent work,
  # then the parent also needs to be reindexed.
  def parent_needs_reindex?(file_set)
    return false unless file_set.parent
    file_set.parent.thumbnail_id == file_set.id
  end
end
