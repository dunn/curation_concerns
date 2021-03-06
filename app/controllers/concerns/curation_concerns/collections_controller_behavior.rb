module CurationConcerns
  module CollectionsControllerBehavior
    extend ActiveSupport::Concern
    include Blacklight::AccessControls::Catalog

    include Blacklight::Base
    include CurationConcerns::SelectsCollections

    included do
      before_action :filter_docs_with_read_access!, except: :show
      before_action :remove_select_something_first_flash, except: :show
      layout 'curation_concerns/1_column'

      include CurationConcerns::Collections::AcceptsBatches

      # This is needed as of BL 3.7
      copy_blacklight_config_from(::CatalogController)

      # Catch permission errors
      rescue_from Hydra::AccessDenied, CanCan::AccessDenied do |exception|
        if exception.action == :edit
          redirect_to(collections.url_for(action: 'show'), alert: 'You do not have sufficient privileges to edit this document')
        elsif current_user && current_user.persisted?
          redirect_to root_url, alert: exception.message
        else
          session['user_return_to'] = request.url
          redirect_to new_user_session_url, alert: exception.message
        end
      end

      # actions: audit, index, create, new, edit, show, update, destroy, permissions, citation
      before_action :authenticate_user!, except: [:show]
      load_and_authorize_resource except: [:index, :show], instance_name: :collection

      class_attribute :presenter_class, :form_class
      self.presenter_class = CurationConcerns::CollectionPresenter
      self.form_class = CurationConcerns::Forms::CollectionEditForm
    end

    def index
      # run the solr query to find the collections
      query = collections_search_builder.with(params).query
      @response = repository.search(query)
      @document_list = @response.documents
    end

    def new
      form
    end

    def show
      presenter
      query_collection_members
    end

    def edit
      query_collection_members
      find_collections
      form
    end

    def after_create
      form
      respond_to do |format|
        ActiveFedora::SolrService.instance.conn.commit
        format.html { redirect_to collection_path(@collection), notice: 'Collection was successfully created.' }
        format.json { render json: @collection, status: :created, location: @collection }
      end
    end

    def after_create_error
      form

      respond_to do |format|
        format.html { render action: 'new' }
        format.json { render json: @collection.errors, status: :unprocessable_entity }
      end
    end

    def create
      @collection.apply_depositor_metadata(current_user.user_key)
      add_members_to_collection unless batch.empty?
      if @collection.save
        after_create
      else
        after_create_error
      end
    end

    def after_update
      if flash[:notice].nil?
        flash[:notice] = 'Collection was successfully updated.'
      end
      respond_to do |format|
        format.html { redirect_to collection_path(@collection) }
        format.json { render json: @collection, status: :updated, location: @collection }
      end
    end

    def after_update_error
      form
      query_collection_members

      respond_to do |format|
        format.html { render action: 'edit' }
        format.json { render json: @collection.errors, status: :unprocessable_entity }
      end
    end

    def update
      process_member_changes
      if @collection.update(collection_params.except(:members))
        after_update
      else
        after_update_error
      end
    end

    def after_destroy(id)
      respond_to do |format|
        format.html { redirect_to search_catalog_path, notice: 'Collection was successfully deleted.' }
        format.json { render json: { id: id }, status: :destroyed, location: @collection }
      end
    end

    def after_destroy_error(id)
      respond_to do |format|
        format.html { redirect_to search_catalog_path, notice: 'Collection could not be deleted.' }
        format.json { render json: { id: id }, status: :destroy_error, location: @collection }
      end
    end

    def destroy
      if @collection.destroy
        after_destroy(params[:id])
      else
        after_destroy_error(params[:id])
      end
    end

    def collection
      action_name == 'show' ? @presenter : @collection
    end

    protected

      def remove_select_something_first_flash
        flash.delete(:notice) if flash.notice == 'Select something first'
      end

      def presenter
        @presenter ||= begin
          # Query Solr for the collection.
          # run the solr query to find the collection members
          response = repository.search(collection_search_builder.query)
          curation_concern = response.documents.first
          raise CanCan::AccessDenied unless curation_concern
          presenter_class.new(curation_concern, current_ability)
        end
      end

      def collection_search_builder
        collection_search_builder_class.new(self).with(params.except(:q, :page))
      end

      def collection_search_builder_class
        CurationConcerns::WorkSearchBuilder
      end

      def collection_member_search_builder_class
        CurationConcerns::CollectionMemberSearchBuilder
      end

      def collection_params
        form_class.model_attributes(params[:collection])
      end

      def form
        @form ||= form_class.new(@collection)
      end

      # Queries Solr for members of the collection.
      # Populates @response and @member_docs similar to Blacklight Catalog#index populating @response and @documents
      def query_collection_members
        params[:q] = params[:cq]
        @response = repository.search(query_for_collection_members)
        @member_docs = @response.documents
      end

      # @return <Hash> a representation of the solr query that find the collection members
      def query_for_collection_members
        collection_member_search_builder.with(params_for_members_query).query
      end

      # You can override this method if you need to provide additional inputs to the search
      # builder. For example:
      #   search_field: 'all_fields'
      # @return <Hash> the inputs required for the collection member search builder
      def params_for_members_query
        params.symbolize_keys.merge(q: params[:cq])
      end

      def collection_member_search_builder
        @collection_member_search_builder ||= collection_member_search_builder_class.new(self)
      end

      def process_member_changes
        case params[:collection][:members]
        when 'add' then add_members_to_collection
        when 'remove' then remove_members_from_collection
        when 'move' then move_members_between_collections
        when Array then assign_batch_to_collection
        end
      end

      def add_members_to_collection(collection = nil)
        collection ||= @collection
        collection.add_members batch
      end

      def remove_members_from_collection
        @collection.members.delete(batch.map { |pid| ActiveFedora::Base.find(pid) })
      end

      def assign_batch_to_collection
        @collection.members(true) # Force the members to get cached before (maybe) removing some of them
        @collection.member_ids = batch
      end

      def move_members_between_collections
        destination_collection = ::Collection.find(params[:destination_collection_id])
        remove_members_from_collection
        add_members_to_collection(destination_collection)
        if destination_collection.save
          flash[:notice] = "Successfully moved #{batch.count} files to #{destination_collection.title} Collection."
        else
          flash[:error] = "An error occured. Files were not moved to #{destination_collection.title} Collection."
        end
      end

      # Include 'catalog' and 'curation_concerns/base' in the search path for views
      def _prefixes
        @_prefixes ||= super + ['catalog', 'curation_concerns/base']
      end
  end # module CollectionsControllerBehavior
end # module Hydra
