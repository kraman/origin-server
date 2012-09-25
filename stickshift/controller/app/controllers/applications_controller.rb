class ApplicationsController < BaseController
  respond_to :xml, :json
  before_filter :authenticate, :check_version
  
  # GET /domains/[domain id]/applications
  def index
    domain_id = params[:domain_id]
    
    begin
      domain = Domain.find_by(owner: @cloud_user, namespace: domain_id)
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Domain '#{domain_id}' not found", 127, "LIST_APPLICATIONS")
    end

    apps = domain.applications.map! { |application| 
      app = nil
      if $requested_api_version >= 1.2
        app = RestApplication12.new(application, get_url, nolinks)
      else
        app = RestApplication10.new(application, get_url, nolinks)
      end
      app
    }
    render_success(:ok, "applications", apps, "LIST_APPLICATIONS", "Found #{apps.length} applications for domain '#{domain_id}'")
  end
  
  # GET /domains/[domain_id]/applications/<id>
  def show
    domain_id = params[:domain_id]
    id = params[:id]
    
    begin
      domain = Domain.find_by(owner: @cloud_user, namespace: domain_id)
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Domain '#{domain_id}' not found", 127, "SHOW_APPLICATION")
    end
    
    begin
      application = Application.find_by(domain: domain, name: id)
      if $requested_api_version >= 1.2
        app = RestApplication12.new(application, get_url, nolinks)
      else
        app = RestApplication10.new(application, get_url, nolinks)
      end
      render_success(:ok, "application", app, "SHOW_APPLICATION", "Application '#{id}' found")
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Application '#{id}' not found", 101, "SHOW_APPLICATION")
    end
  end
  
  # POST /domains/[domain_id]/applications
  def create
    domain_id = params[:domain_id]
    app_name = params[:name]
    feature = params[:cartridge]
    template_id = params[:template]
    
    begin
      domain = Domain.find_by(owner: @cloud_user, namespace: domain_id)
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Domain '#{domain_id}' not found", 127,"ADD_APPLICATION")
    end
    
    if Application.where(domain: domain, name: app_name).count > 0
      return render_error(:unprocessable_entity, "The supplied application name '#{app_name}' already exists", 100, "ADD_APPLICATION", "name")
    end

    begin
      application = Application.create_app(app_name, [feature], domain, "small", ResultIO.new)
    rescue StickShift::UnfulfilledRequirementException => e
      return render_error(:unprocessable_entity, "Unable to create application for #{e.feature}", 109, "ADD_APPLICATION", "cartridge")
    rescue ApplicationValidationException => e
      messages = get_error_messages(e.app)
      return render_error(:unprocessable_entity, nil, nil, "ADD_APPLICATION", nil, nil, messages)
    end

   if $requested_api_version >= 1.2
     app = RestApplication12.new(application, get_url, nolinks)
   else
     app = RestApplication10.new(application, get_url, nolinks)
   end
   reply = RestReply.new( :created, "application", app)
   message = Message.new(:info, "Application #{application.name} was created.")
   render_success(:created, "application", app, "ADD_APPLICATION", nil, nil, nil, [message]) 
  end
  
  # DELELTE domains/[domain_id]/applications/[id]
  def destroy
    domain_id = params[:domain_id]
    id = params[:id]    
    
    begin
      domain = Domain.find_by(owner: @cloud_user, namespace: domain_id)
      log_action(@request_id, @cloud_user._id.to_s, @cloud_user.login, "DELETE_APPLICATION", true, "Found domain #{domain_id}")
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Domain #{domain_id} not found", 127, "DELETE_APPLICATION")
    end
    
    begin
      application = Application.find_by(domain: domain, name: id)
    rescue Mongoid::Errors::DocumentNotFound
      return render_error(:not_found, "Application #{id} not found.", 101,"DELETE_APPLICATION")
    end
    
    # create tasks to delete gear groups
    application.destroy_app
    render_success(:no_content, nil, nil, "DELETE_APPLICATION", "Application #{id} is deleted.", true) 
  end
end
