require 'yajl'
require_relative '../spec_helper'

describe AdminUI::Admin, type: :integration do
  include_context :server_context

  def create_http
    Net::HTTP.new(host, port)
  end

  def login_and_return_cookie(http)
    response = nil
    cookie = nil
    uri = URI.parse('/')
    loop do
      path  = uri.path
      path += "?#{uri.query}" unless uri.query.nil?

      request = Net::HTTP::Get.new(path)
      request['Cookie'] = cookie

      response = http.request(request)
      cookie   = response['Set-Cookie'] unless response['Set-Cookie'].nil?

      break unless response['location']
      uri = URI.parse(response['location'])
    end

    expect(cookie).to_not be_nil

    cookie
  end

  def _get_request(path)
    request = Net::HTTP::Get.new(path)
    request['Cookie'] = cookie
    http.request(request)
  end

  def get_response(path)
    response = _get_request(path)
    check_ok_response(response)
    response
  end

  def get_response_for_invalid_path(path)
    response = _get_request(path)
    check_notfound_response(response)
    response
  end

  def verify_sys_log_entries(operations_msgs, escapes = false)
    found_match = 0
    File.readlines(log_file).each do |line|
      line.chomp!
      next unless line =~ /\[ admin \] : \[ /
      operations_msgs.each do |op_msg|
        op  = op_msg[0]
        msg = op_msg[1]
        esmsg = msg
        esmsg = Regexp.escape(msg) if escapes
        next unless line =~ /\[ admin \] : \[ #{op} \] : #{esmsg}/
        found_match += 1
        break
      end
    end
    expect(found_match).to be >= operations_msgs.length
  end

  def check_ok_response(response)
    expect(response.is_a?(Net::HTTPOK)).to be(true)
  end

  def check_notfound_response(response)
    expect(response.is_a?(Net::HTTPNotFound)).to be(true)
    expect(response.body).to eq('Page Not Found')
  end

  def get_json(path, escapes = false)
    response = get_response(path)

    body = response.body
    expect(body).to_not be_nil
    verify_sys_log_entries([['get', path]], escapes)
    Yajl::Parser.parse(body)
  end

  def post_request(path, body)
    request = Net::HTTP::Post.new(path)
    request['Cookie'] = cookie
    request['Content-Length'] = 0
    request.body = body if body
    http.request(request)
  end

  def post_request_for_invalid_path(path, body)
    response = post_request(path, body)
    check_notfound_response(response)
    response
  end

  def put_request(path, body = nil)
    request = Net::HTTP::Put.new(path)
    request['Cookie'] = cookie
    request['Content-Length'] = 0
    request.body = body if body
    http.request(request)
  end

  def put_request_for_invalid_path(path, body)
    response = put_request(path, body)
    check_notfound_response(response)
    response
  end

  def delete_request(path)
    request = Net::HTTP::Delete.new(path)
    request['Cookie'] = cookie
    request['Content-Length'] = 0
    http.request(request)
  end

  def delete_request_for_invalid_path(path)
    response = delete_request(path)
    check_notfound_response(response)
    response
  end

  shared_examples 'common_check_request_path' do
    let(:http)   { create_http }
    let(:cookie) {}
    it 'returns the 404 code if the get url is invalid' do
      get_response_for_invalid_path('/foo')
    end

    it 'returns the 404 code if the put url is invalid' do
      put_request_for_invalid_path('/foo', '{"state":"STOPPED"}')
    end

    it 'returns the 404 code if the post url is invalid' do
      post_request_for_invalid_path('/foo', '{"name":"new_org"}')
    end

    it 'returns the 404 code if the delete url is invalid' do
      delete_request_for_invalid_path('/foo')
    end
  end

  context 'returns the 404 code if the url is wrong without login' do
    it_behaves_like('common_check_request_path')
  end

  context 'returns the 404 code if the url is wrong with login' do
    let(:cookie) { login_and_return_cookie(http) }
    it_behaves_like('common_check_request_path')
  end

  context 'manage application' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/applications_view_model')['items']['items'][0][3]).to eq('STARTED')
    end

    def rename_app
      response = put_request("/applications/#{cc_app[:guid]}", "{\"name\":\"#{cc_app_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/applications/#{cc_app[:guid]}; body = {\"name\":\"#{cc_app_rename}\"}"]], true)
    end

    def stop_app
      response = put_request("/applications/#{cc_app[:guid]}", '{"state":"STOPPED"}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/applications/#{cc_app[:guid]}; body = {\"state\":\"STOPPED\"}"]], true)
    end

    def start_app
      response = put_request("/applications/#{cc_app[:guid]}", '{"state":"STARTED"}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/applications/#{cc_app[:guid]}; body = {\"state\":\"STARTED\"}"]], true)
    end

    def restage_app
      response = post_request("/applications/#{cc_app[:guid]}/restage", '{}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['post', "/applications/#{cc_app[:guid]}/restage"]], true)
    end

    def delete_app
      response = delete_request("/applications/#{cc_app[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/applications/#{cc_app[:guid]}"]])
    end

    def delete_app_recursive
      response = delete_request("/applications/#{cc_app[:guid]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/applications/#{cc_app[:guid]}?recursive=true"]], true)
    end

    it 'has user name and applications in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/applications_view_model']], true)
    end

    it 'renames an application' do
      expect { rename_app }.to change { get_json('/applications_view_model')['items']['items'][0][1] }.from(cc_app[:name]).to(cc_app_rename)
    end

    it 'stops a running application' do
      expect { stop_app }.to change { get_json('/applications_view_model')['items']['items'][0][3] }.from('STARTED').to('STOPPED')
    end

    it 'starts a stopped application' do
      stop_app
      expect { start_app }.to change { get_json('/applications_view_model')['items']['items'][0][3] }.from('STOPPED').to('STARTED')
    end

    it 'restages stopped application' do
      restage_app
    end

    it 'deletes an application' do
      expect { delete_app }.to change { get_json('/applications_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes an application recursive' do
      expect { delete_app_recursive }.to change { get_json('/applications_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage application instance' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/application_instances_view_model')['items']['items'].length).to eq(1)
    end

    def delete_app_instance
      response = delete_request("/applications/#{cc_app[:guid]}/#{cc_app_instance_index}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/applications/#{cc_app[:guid]}/#{cc_app_instance_index}"]])
    end

    it 'has user name and application instances request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/application_instances_view_model']], true)
    end

    it 'deletes an application instance' do
      expect { delete_app_instance }.to change { get_json('/application_instances_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage buildpack' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/buildpacks_view_model')['items']['items'].length).to eq(1)
    end

    def rename_buildpack
      response = put_request("/buildpacks/#{cc_buildpack[:guid]}", "{\"name\":\"#{cc_buildpack_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/buildpacks/#{cc_buildpack[:guid]}; body = {\"name\":\"#{cc_buildpack_rename}\"}"]], true)
    end

    def make_buildpack_disabled
      response = put_request("/buildpacks/#{cc_buildpack[:guid]}", '{"enabled":false}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/buildpacks/#{cc_buildpack[:guid]}; body = {\"enabled\":false}"]], true)
    end

    def make_buildpack_enabled
      response = put_request("/buildpacks/#{cc_buildpack[:guid]}", '{"enabled":true}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/buildpacks/#{cc_buildpack[:guid]}; body = {\"enabled\":true}"]], true)
    end

    def make_buildpack_locked
      response = put_request("/buildpacks/#{cc_buildpack[:guid]}", '{"locked":true}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/buildpacks/#{cc_buildpack[:guid]}; body = {\"locked\":true}"]], true)
    end

    def make_buildpack_unlocked
      response = put_request("/buildpacks/#{cc_buildpack[:guid]}", '{"locked":false}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/buildpacks/#{cc_buildpack[:guid]}; body = {\"locked\":false}"]], true)
    end

    def delete_buildpack
      response = delete_request("/buildpacks/#{cc_buildpack[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/buildpacks/#{cc_buildpack[:guid]}"]])
    end

    it 'has user name and buildpack request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/buildpacks_view_model']], true)
    end

    it 'renames a buildpack' do
      expect { rename_buildpack }.to change { get_json('/buildpacks_view_model')['items']['items'][0][1] }.from(cc_buildpack[:name]).to(cc_buildpack_rename)
    end

    it 'disables buildpack' do
      expect { make_buildpack_disabled }.to change { get_json('/buildpacks_view_model')['items']['items'][0][6].to_s }.from('true').to('false')
    end

    it 'enables buildpack' do
      make_buildpack_disabled
      expect { make_buildpack_enabled }.to change { get_json('/buildpacks_view_model')['items']['items'][0][6].to_s }.from('false').to('true')
    end

    it 'locks buildpack' do
      expect { make_buildpack_locked }.to change { get_json('/buildpacks_view_model')['items']['items'][0][7].to_s }.from('false').to('true')
    end

    it 'unlocks buildpack' do
      make_buildpack_locked
      expect { make_buildpack_unlocked }.to change { get_json('/buildpacks_view_model')['items']['items'][0][7].to_s }.from('true').to('false')
    end

    it 'deletes a buildpack' do
      expect { delete_buildpack }.to change { get_json('/buildpacks_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage cell' do
    let(:application_instance_source) { :doppler_cell }
    let(:http)                        { create_http }
    let(:cookie)                      { login_and_return_cookie(http) }

    before do
      expect(get_json('/cells_view_model')['items']['items'].length).to eq(1)
    end

    def delete_cell
      response = delete_request("/doppler_components?uri=#{rep_envelope.origin}:#{rep_envelope.index}:#{rep_envelope.ip}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/doppler_components?uri=#{rep_envelope.origin}:#{rep_envelope.index}:#{rep_envelope.ip}"]], true)
    end

    it 'has user name and cells request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/cells_view_model']], true)
    end

    it 'deletes a cell' do
      expect { delete_cell }.to change { get_json('/cells_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage client' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/clients_view_model')['items']['items'].length).to eq(1)
    end

    def delete_client
      response = delete_request("/clients/#{uaa_client[:client_id]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/clients/#{uaa_client[:client_id]}"]])
    end

    it 'has user name and clients request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/clients_view_model']], true)
    end

    it 'deletes a client' do
      expect { delete_client }.to change { get_json('/clients_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage cloud controller' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/cloud_controllers_view_model')['items']['items'].length).to eq(1)
    end

    def delete_cloud_controller
      response = delete_request("/components?uri=#{nats_cloud_controller_varz}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/components?uri=#{nats_cloud_controller_varz}"]], true)
    end

    it 'has user name and cloud controllers request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/cloud_controllers_view_model']], true)
    end

    it 'deletes a cloud controller' do
      expect { delete_cloud_controller }.to change { get_json('/cloud_controllers_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage dea' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/deas_view_model')['items']['items'].length).to eq(1)
    end

    def delete_dea(uri)
      response = delete_request(uri)
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', uri]], true)
    end

    it 'has user name and deas request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/deas_view_model']], true)
    end

    context 'varz dea' do
      it 'deletes a dea' do
        expect { delete_dea("/components?uri=#{nats_dea_varz}") }.to change { get_json('/deas_view_model')['items']['items'].length }.from(1).to(0)
      end
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it 'deletes a dea' do
        expect { delete_dea("/doppler_components?uri=#{dea_envelope.origin}:#{dea_envelope.index}:#{dea_envelope.ip}") }.to change { get_json('/deas_view_model')['items']['items'].length }.from(1).to(0)
      end
    end
  end

  context 'manage domain' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/domains_view_model')['items']['items'].length).to eq(1)
    end

    def delete_domain
      response = delete_request("/domains/#{cc_domain[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/domains/#{cc_domain[:guid]}"]])
    end

    def delete_domain_recursive
      response = delete_request("/domains/#{cc_domain[:guid]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/domains/#{cc_domain[:guid]}?recursive=true"]], true)
    end

    it 'has user name and domains request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/domains_view_model']], true)
    end

    it 'deletes a domain' do
      expect { delete_domain }.to change { get_json('/domains_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes a domain recursive' do
      expect { delete_domain_recursive }.to change { get_json('/domains_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage feature flag' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/feature_flags_view_model')['items']['items'].length).to eq(1)
    end

    def make_feature_flag_disabled
      response = put_request("/feature_flags/#{cc_feature_flag[:name]}", '{"enabled":false}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/feature_flags/#{cc_feature_flag[:name]}; body = {\"enabled\":false}"]], true)
    end

    def make_feature_flag_enabled
      response = put_request("/feature_flags/#{cc_feature_flag[:name]}", '{"enabled":true}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/feature_flags/#{cc_feature_flag[:name]}; body = {\"enabled\":true}"]], true)
    end

    it 'has user name and feature flag request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/feature_flags_view_model']], true)
    end

    it 'disables feature flag' do
      expect { make_feature_flag_disabled }.to change { get_json('/feature_flags_view_model')['items']['items'][0][5].to_s }.from('true').to('false')
    end

    it 'enables feature flag' do
      make_feature_flag_disabled
      expect { make_feature_flag_enabled }.to change { get_json('/feature_flags_view_model')['items']['items'][0][5].to_s }.from('false').to('true')
    end
  end

  context 'manage gateway' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/gateways_view_model')['items']['items'].length).to eq(1)
    end

    def delete_gateway
      response = delete_request("/components?uri=#{nats_provisioner_varz}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/components?uri=#{nats_provisioner_varz}"]], true)
    end

    it 'has user name and gateways request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/gateways_view_model']], true)
    end

    it 'deletes a gateway' do
      expect { delete_gateway }.to change { get_json('/gateways_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage group' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/groups_view_model')['items']['items'].length).to eq(1)
    end

    def delete_group
      response = delete_request("/groups/#{uaa_group[:id]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/groups/#{uaa_group[:id]}"]])
    end

    it 'has user name and groups request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/groups_view_model']], true)
    end

    it 'deletes a group' do
      expect { delete_group }.to change { get_json('/groups_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage health manager' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/health_managers_view_model')['items']['items'].length).to eq(1)
    end

    def delete_health_manager(uri)
      response = delete_request(uri)
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', uri]], true)
    end

    it 'has user name and health managers request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/health_managers_view_model']], true)
    end

    context 'varz dea' do
      it 'deletes a health manager' do
        expect { delete_health_manager("/components?uri=#{nats_health_manager_varz}") }.to change { get_json('/health_managers_view_model')['items']['items'].length }.from(1).to(0)
      end
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it 'deletes a health manager' do
        expect { delete_health_manager("/doppler_components?uri=#{analyzer_envelope.origin}:#{analyzer_envelope.index}:#{analyzer_envelope.ip}") }.to change { get_json('/health_managers_view_model')['items']['items'].length }.from(1).to(0)
      end
    end
  end

  context 'manage organization' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/organizations_view_model')['items']['items'].length).to eq(1)
    end

    def create_organization
      response = post_request('/organizations', "{\"name\":\"#{cc_organization2[:name]}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['post', "/organizations; body = {\"name\":\"#{cc_organization2[:name]}\"}"]], true)
    end

    def rename_organization
      response = put_request("/organizations/#{cc_organization[:guid]}", "{\"name\":\"#{cc_organization_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/organizations/#{cc_organization[:guid]}; body = {\"name\":\"#{cc_organization_rename}\"}"]], true)
    end

    def set_quota
      response = put_request("/organizations/#{cc_organization[:guid]}", "{\"quota_definition_guid\":\"#{cc_quota_definition2[:guid]}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/organizations/#{cc_organization[:guid]}; body = {\"quota_definition_guid\":\"#{cc_quota_definition2[:guid]}\"}"]], true)
    end

    def activate_organization
      response = put_request("/organizations/#{cc_organization[:guid]}", '{"status":"active"}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/organizations/#{cc_organization[:guid]}; body = {\"status\":\"active\"}"]], true)
    end

    def suspend_organization
      response = put_request("/organizations/#{cc_organization[:guid]}", '{"status":"suspended"}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/organizations/#{cc_organization[:guid]}; body = {\"status\":\"suspended\"}"]], true)
    end

    def delete_organization
      response = delete_request("/organizations/#{cc_organization[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/organizations/#{cc_organization[:guid]}"]])
    end

    def delete_organization_recursive
      response = delete_request("/organizations/#{cc_organization[:guid]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/organizations/#{cc_organization[:guid]}?recursive=true"]], true)
    end

    it 'has user name and organizations request in the log file' do
      verify_sys_log_entries([['get', '/organizations_view_model']])
    end

    it 'creates an organization' do
      expect { create_organization }.to change { get_json('/organizations_view_model')['items']['items'].length }.from(1).to(2)
      expect(get_json('/organizations_view_model', false)['items']['items'][1][1]).to eq(cc_organization2[:name])
    end

    it 'renames an organization' do
      expect { rename_organization }.to change { get_json('/organizations_view_model')['items']['items'][0][1] }.from(cc_organization[:name]).to(cc_organization_rename)
    end

    context 'sets the quota for organization' do
      let(:insert_second_quota_definition) { true }
      it 'sets the quota for organization' do
        expect { set_quota }.to change { get_json('/organizations_view_model')['items']['items'][0][10] }.from(cc_quota_definition[:name]).to(cc_quota_definition2[:name])
      end
    end

    it 'activates the organization' do
      suspend_organization
      expect { activate_organization }.to change { get_json('/organizations_view_model')['items']['items'][0][3] }.from('suspended').to('active')
    end

    it 'suspends the organization' do
      expect { suspend_organization }.to change { get_json('/organizations_view_model')['items']['items'][0][3] }.from('active').to('suspended')
    end

    it 'deletes an organization' do
      expect { delete_organization }.to change { get_json('/organizations_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes an organization recursive' do
      expect { delete_organization_recursive }.to change { get_json('/organizations_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage organization role' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/organization_roles_view_model')['items']['items'].length).to eq(4)
    end

    def delete_organization_role
      response = delete_request("/organizations/#{cc_organization[:guid]}/auditors/#{cc_user[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/organizations/#{cc_organization[:guid]}/auditors/#{cc_user[:guid]}"]])
    end

    it 'has user name and organization roles request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/organization_roles_view_model']], true)
    end

    it 'deletes an organization role' do
      expect { delete_organization_role }.to change { get_json('/organization_roles_view_model')['items']['items'].length }.from(4).to(3)
    end
  end

  context 'manage quota' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/quotas_view_model')['items']['items'].length).to eq(1)
    end

    def rename_quota
      response = put_request("/quota_definitions/#{cc_quota_definition[:guid]}", "{\"name\":\"#{cc_quota_definition_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/quota_definitions/#{cc_quota_definition[:guid]}; body = {\"name\":\"#{cc_quota_definition_rename}\"}"]], true)
    end

    def delete_quota
      response = delete_request("/quota_definitions/#{cc_quota_definition[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/quota_definitions/#{cc_quota_definition[:guid]}"]])
    end

    it 'has user name and quotas request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/quotas_view_model']], true)
    end

    it 'renames a quota' do
      expect { rename_quota }.to change { get_json('/quotas_view_model')['items']['items'][0][1] }.from(cc_quota_definition[:name]).to(cc_quota_definition_rename)
    end

    it 'deletes a quota' do
      expect { delete_quota }.to change { get_json('/quotas_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage route' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/routes_view_model')['items']['items'].length).to eq(1)
    end

    def delete_route
      response = delete_request("/routes/#{cc_route[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/routes/#{cc_route[:guid]}"]])
    end

    def delete_route_recursive
      response = delete_request("/routes/#{cc_route[:guid]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/routes/#{cc_route[:guid]}?recursive=true"]], true)
    end

    it 'has user name and routes request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/routes_view_model']], true)
    end

    it 'deletes a route' do
      expect { delete_route }.to change { get_json('/routes_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes a route recursive' do
      expect { delete_route_recursive }.to change { get_json('/routes_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage router' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/routers_view_model')['items']['items'].length).to eq(1)
    end

    def delete_router(uri)
      response = delete_request(uri)
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', uri]], true)
    end

    it 'has user name and routers request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/routers_view_model']], true)
    end

    context 'varz dea' do
      it 'deletes a router' do
        expect { delete_router("/components?uri=#{nats_router_varz}") }.to change { get_json('/routers_view_model')['items']['items'].length }.from(1).to(0)
      end
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it 'deletes a router' do
        expect { delete_router("/doppler_components?uri=#{gorouter_envelope.origin}:#{gorouter_envelope.index}:#{gorouter_envelope.ip}") }.to change { get_json('/routers_view_model')['items']['items'].length }.from(1).to(0)
      end
    end
  end

  context 'manage security group' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/security_groups_view_model')['items']['items'].length).to eq(1)
    end

    def delete_security_group
      response = delete_request("/security_groups/#{cc_security_group[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/security_groups/#{cc_security_group[:guid]}"]])
    end

    it 'has user name and security groups request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/security_groups_view_model']], true)
    end

    it 'deletes a security group' do
      expect { delete_security_group }.to change { get_json('/security_groups_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage security group space' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/security_groups_spaces_view_model')['items']['items'].length).to eq(1)
    end

    def delete_security_group_space
      response = delete_request("/security_groups/#{cc_security_group[:guid]}/#{cc_space[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/security_groups/#{cc_security_group[:guid]}/#{cc_space[:guid]}"]])
    end

    it 'has user name and security groups request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/security_groups_spaces_view_model']], true)
    end

    it 'deletes a security group space' do
      expect { delete_security_group_space }.to change { get_json('/security_groups_spaces_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/services_view_model')['items']['items'].length).to eq(1)
    end

    def delete_service
      response = delete_request("/services/#{cc_service[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/services/#{cc_service[:guid]}"]])
    end

    def purge_service
      response = delete_request("/services/#{cc_service[:guid]}?purge=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/services/#{cc_service[:guid]}?purge=true"]], true)
    end

    it 'has user name and services request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/services_view_model']], true)
    end

    it 'deletes a service' do
      expect { delete_service }.to change { get_json('/services_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'purges a service' do
      expect { purge_service }.to change { get_json('/services_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service binding' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_bindings_view_model')['items']['items'].length).to eq(1)
    end

    def delete_service_binding
      response = delete_request("/service_bindings/#{cc_service_binding[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_bindings/#{cc_service_binding[:guid]}"]])
    end

    it 'has user name and service bindings request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_bindings_view_model']], true)
    end

    it 'deletes a service binding' do
      expect { delete_service_binding }.to change { get_json('/service_bindings_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service broker' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_brokers_view_model')['items']['items'].length).to eq(1)
    end

    def rename_service_broker
      response = put_request("/service_brokers/#{cc_service_broker[:guid]}", "{\"name\":\"#{cc_service_broker_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/service_brokers/#{cc_service_broker[:guid]}; body = {\"name\":\"#{cc_service_broker_rename}\"}"]], true)
    end

    def delete_service_broker
      response = delete_request("/service_brokers/#{cc_service_broker[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_brokers/#{cc_service_broker[:guid]}"]])
    end

    it 'has user name and service brokers request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_brokers_view_model']], true)
    end

    it 'renames a service broker' do
      expect { rename_service_broker }.to change { get_json('/service_brokers_view_model')['items']['items'][0][1] }.from(cc_service_broker[:name]).to(cc_service_broker_rename)
    end

    it 'deletes a service broker' do
      expect { delete_service_broker }.to change { get_json('/service_brokers_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service instance' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_instances_view_model')['items']['items'].length).to eq(1)
    end

    def rename_service_instance
      response = put_request("/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}", "{\"name\":\"#{cc_service_instance_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}; body = {\"name\":\"#{cc_service_instance_rename}\"}"]], true)
    end

    def delete_service_instance
      response = delete_request("/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}"]])
    end

    def delete_service_instance_recursive
      response = delete_request("/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}?recursive=true"]], true)
    end

    def delete_service_instance_recursive_purge
      response = delete_request("/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}?recursive=true&purge=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_instances/#{cc_service_instance[:guid]}/#{cc_service_instance[:is_gateway_service]}?recursive=true&purge=true"]], true)
    end

    it 'has user name and service instances request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_instances_view_model']], true)
    end

    it 'renames a service instance' do
      expect { rename_service_instance }.to change { get_json('/service_instances_view_model')['items']['items'][0][1] }.from(cc_service_instance[:name]).to(cc_service_instance_rename)
    end

    it 'deletes a service instance' do
      expect { delete_service_instance }.to change { get_json('/service_instances_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes a service instance recursive' do
      expect { delete_service_instance_recursive }.to change { get_json('/service_instances_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes a service instance recursive purge' do
      expect { delete_service_instance_recursive_purge }.to change { get_json('/service_instances_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service key' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_keys_view_model')['items']['items'].length).to eq(1)
    end

    def delete_service_key
      response = delete_request("/service_keys/#{cc_service_key[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_keys/#{cc_service_key[:guid]}"]])
    end

    it 'has user name and service keys request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_keys_view_model']], true)
    end

    it 'deletes a service key' do
      expect { delete_service_key }.to change { get_json('/service_keys_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service plan' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_plans_view_model')['items']['items'].length).to eq(1)
    end

    def make_service_plan_private
      response = put_request("/service_plans/#{cc_service_plan[:guid]}", '{"public":false}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/service_plans/#{cc_service_plan[:guid]}; body = {\"public\":false}"]], true)
    end

    def make_service_plan_public
      response = put_request("/service_plans/#{cc_service_plan[:guid]}", '{"public":true}')
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/service_plans/#{cc_service_plan[:guid]}; body = {\"public\":true}"]], true)
    end

    def delete_service_plan
      response = delete_request("/service_plans/#{cc_service_plan[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_plans/#{cc_service_plan[:guid]}"]])
    end

    it 'has user name and service plan request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_plans_view_model']], true)
    end

    it 'makes service plan private' do
      expect { make_service_plan_private }.to change { get_json('/service_plans_view_model')['items']['items'][0][7].to_s }.from('true').to('false')
    end

    it 'makes service plan public' do
      make_service_plan_private
      expect { make_service_plan_public }.to change { get_json('/service_plans_view_model')['items']['items'][0][7].to_s }.from('false').to('true')
    end

    it 'deletes a service plan' do
      expect { delete_service_plan }.to change { get_json('/service_plans_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage service plan visibility' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/service_plan_visibilities_view_model')['items']['items'].length).to eq(1)
    end

    def delete_service_plan_visibility
      response = delete_request("/service_plan_visibilities/#{cc_service_plan_visibility[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/service_plan_visibilities/#{cc_service_plan_visibility[:guid]}"]])
    end

    it 'has user name and service plan visibility request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/service_plan_visibilities_view_model']], true)
    end

    it 'deletes a service plan visibility' do
      expect { delete_service_plan_visibility }.to change { get_json('/service_plan_visibilities_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage space' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/spaces_view_model')['items']['items'].length).to eq(1)
    end

    def rename_space
      response = put_request("/spaces/#{cc_space[:guid]}", "{\"name\":\"#{cc_space_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/spaces/#{cc_space[:guid]}; body = {\"name\":\"#{cc_space_rename}\"}"]], true)
    end

    def delete_space
      response = delete_request("/spaces/#{cc_space[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/spaces/#{cc_space[:guid]}"]])
    end

    def delete_space_recursive
      response = delete_request("/spaces/#{cc_space[:guid]}?recursive=true")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/spaces/#{cc_space[:guid]}?recursive=true"]], true)
    end

    it 'has user name and space request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/spaces_view_model']], true)
    end

    it 'renames a space' do
      expect { rename_space }.to change { get_json('/spaces_view_model')['items']['items'][0][1] }.from(cc_space[:name]).to(cc_space_rename)
    end

    it 'deletes a space' do
      expect { delete_space }.to change { get_json('/spaces_view_model')['items']['items'].length }.from(1).to(0)
    end

    it 'deletes a space recursive' do
      expect { delete_space_recursive }.to change { get_json('/spaces_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage space quota' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/space_quotas_view_model')['items']['items'].length).to eq(1)
    end

    def rename_space_quota
      response = put_request("/space_quota_definitions/#{cc_space_quota_definition[:guid]}", "{\"name\":\"#{cc_space_quota_definition_rename}\"}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/space_quota_definitions/#{cc_space_quota_definition[:guid]}; body = {\"name\":\"#{cc_space_quota_definition_rename}\"}"]], true)
    end

    def delete_space_quota
      response = delete_request("/space_quota_definitions/#{cc_space_quota_definition[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/space_quota_definitions/#{cc_space_quota_definition[:guid]}"]])
    end

    it 'has user name and quotas request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/space_quotas_view_model']], true)
    end

    it 'renames a space quota' do
      expect { rename_space_quota }.to change { get_json('/space_quotas_view_model')['items']['items'][0][1] }.from(cc_space_quota_definition[:name]).to(cc_space_quota_definition_rename)
    end

    it 'deletes a space quota' do
      expect { delete_space_quota }.to change { get_json('/space_quotas_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'manage space quota space' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    def create_space_quota_space
      response = put_request("/space_quota_definitions/#{cc_space_quota_definition2[:guid]}/spaces/#{cc_space[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['put', "/space_quota_definitions/#{cc_space_quota_definition2[:guid]}/spaces/#{cc_space[:guid]}"]], true)
    end

    def delete_space_quota_space
      response = delete_request("/space_quota_definitions/#{cc_space_quota_definition[:guid]}/spaces/#{cc_space[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/space_quota_definitions/#{cc_space_quota_definition[:guid]}/spaces/#{cc_space[:guid]}"]])
    end

    context 'deletes a space quota space' do
      before do
        expect(get_json('/space_quotas_view_model')['items']['items'].length).to eq(1)
      end

      it 'deletes a space quota space' do
        expect { delete_space_quota_space }.to change { get_json('/spaces_view_model')['items']['items'][0][9] }.from(cc_space_quota_definition[:name]).to(nil)
      end
    end

    context 'sets a space quota for space' do
      let(:insert_second_quota_definition) { true }
      before do
        expect(get_json('/space_quotas_view_model')['items']['items'].length).to eq(2)
      end

      it 'sets a space quota for space' do
        expect { create_space_quota_space }.to change { get_json('/spaces_view_model')['items']['items'][0][9] }.from(cc_space_quota_definition[:name]).to(cc_space_quota_definition2[:name])
      end
    end
  end

  context 'manage space role' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/space_roles_view_model')['items']['items'].length).to eq(3)
    end

    def delete_space_role
      response = delete_request("/spaces/#{cc_space[:guid]}/auditors/#{cc_user[:guid]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/spaces/#{cc_space[:guid]}/auditors/#{cc_user[:guid]}"]])
    end

    it 'has user name and space roles request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/space_roles_view_model']], true)
    end

    it 'deletes a space role' do
      expect { delete_space_role }.to change { get_json('/space_roles_view_model')['items']['items'].length }.from(3).to(2)
    end
  end

  context 'manage user' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    before do
      expect(get_json('/users_view_model')['items']['items'].length).to eq(1)
    end

    def delete_user
      response = delete_request("/users/#{uaa_user[:id]}")
      expect(response.is_a?(Net::HTTPNoContent)).to be(true)
      verify_sys_log_entries([['delete', "/users/#{uaa_user[:id]}"]])
    end

    it 'has user name and users request in the log file' do
      verify_sys_log_entries([['authenticated', 'is admin? true'], ['get', '/users_view_model']], true)
    end

    it 'deletes a user' do
      expect { delete_user }.to change { get_json('/users_view_model')['items']['items'].length }.from(1).to(0)
    end
  end

  context 'retrieves and validates' do
    let(:http)   { create_http }
    let(:cookie) { login_and_return_cookie(http) }

    shared_examples 'retrieves view_model' do
      let(:retrieved) { get_json(path) }
      it 'retrieves' do
        expect(retrieved).to_not be(nil)
        expect(retrieved['recordsTotal']).to eq(view_model_source.length)
        expect(retrieved['recordsFiltered']).to eq(view_model_source.length)
        outer_items = retrieved['items']
        expect(outer_items).to_not be(nil)
        expect(outer_items['connected']).to eq(true)
        inner_items = outer_items['items']
        expect(inner_items).to_not be(nil)

        view_model_source.each do |view_model|
          expect(Yajl::Parser.parse(Yajl::Encoder.encode(inner_items))).to include(Yajl::Parser.parse(Yajl::Encoder.encode(view_model)))
        end
      end
    end

    shared_examples 'retrieves view_model detail' do
      let(:retrieved) { get_json(path) }
      it 'retrieves' do
        expect(Yajl::Parser.parse(Yajl::Encoder.encode(view_model_source))).to eq(Yajl::Parser.parse(Yajl::Encoder.encode(retrieved)))
      end
    end

    shared_examples 'application_instances' do
      context 'application_instances_view_model' do
        let(:event_type)        { 'app' }
        let(:path)              { '/application_instances_view_model' }
        let(:view_model_source) { view_models_application_instances }
        it_behaves_like('retrieves view_model')
      end

      context 'application_instances_view_model detail' do
        let(:path)              { "/application_instances_view_model/#{cc_app[:guid]}/#{cc_app_instance_index}/#{varz_application_instance_id}" }
        let(:view_model_source) { view_models_application_instances_detail }
        it_behaves_like('retrieves view_model detail')
      end
    end

    context 'varz dea' do
      it_behaves_like('application_instances')
    end

    context 'doppler cell' do
      let(:application_instance_source) { :doppler_cell }
      it_behaves_like('application_instances')
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('application_instances')
    end

    shared_examples 'applications' do
      context 'applications_view_model' do
        let(:event_type)        { 'app' }
        let(:path)              { '/applications_view_model' }
        let(:view_model_source) { view_models_applications }
        it_behaves_like('retrieves view_model')
      end

      context 'applications_view_model detail' do
        let(:path)              { "/applications_view_model/#{cc_app[:guid]}" }
        let(:view_model_source) { view_models_applications_detail }
        it_behaves_like('retrieves view_model detail')
      end
    end

    context 'varz dea' do
      it_behaves_like('applications')
    end

    context 'doppler cell' do
      let(:application_instance_source) { :doppler_cell }
      it_behaves_like('applications')
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('applications')
    end

    context 'buildpacks_view_model' do
      let(:path)              { '/buildpacks_view_model' }
      let(:view_model_source) { view_models_buildpacks }
      it_behaves_like('retrieves view_model')
    end

    context 'buildpacks_view_model detail' do
      let(:path)              { "/buildpacks_view_model/#{cc_buildpack[:guid]}" }
      let(:view_model_source) { view_models_buildpacks_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'cells_view_model' do
      let(:application_instance_source) { :doppler_cell }
      let(:path)                        { '/cells_view_model' }
      let(:view_model_source)           { view_models_cells }
      it_behaves_like('retrieves view_model')
    end

    context 'cells_view_model detail' do
      let(:application_instance_source) { :doppler_cell }
      let(:path)                        { "/cells_view_model/#{rep_envelope.ip}:#{rep_envelope.index}" }
      let(:view_model_source)           { view_models_cells_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'clients_view_model' do
      let(:event_type)        { 'service_dashboard_client' }
      let(:path)              { '/clients_view_model' }
      let(:view_model_source) { view_models_clients }
      it_behaves_like('retrieves view_model')
    end

    context 'clients_view_model detail' do
      let(:path)              { "/clients_view_model/#{uaa_client[:client_id]}" }
      let(:view_model_source) { view_models_clients_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'cloud_controllers_view_model' do
      let(:path)              { '/cloud_controllers_view_model' }
      let(:view_model_source) { view_models_cloud_controllers }
      it_behaves_like('retrieves view_model')
    end

    context 'cloud_controllers_view_model detail' do
      let(:path)              { "/cloud_controllers_view_model/#{nats_cloud_controller['host']}" }
      let(:view_model_source) { view_models_cloud_controllers_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'components_view_model' do
      let(:path)              { '/components_view_model' }
      let(:view_model_source) { view_models_components }
      it_behaves_like('retrieves view_model')
    end

    context 'components_view_model detail' do
      let(:path)              { "/components_view_model/#{nats_cloud_controller['host']}" }
      let(:view_model_source) { view_models_components_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'current_statistics' do
      let(:retrieved) { get_json('/current_statistics') }

      context 'varz dea' do
        it 'retrieves' do
          expect(retrieved).to include('apps'              => 1,
                                       'cells'             => 0,
                                       'deas'              => 1,
                                       'organizations'     => 1,
                                       'running_instances' => cc_app[:instances],
                                       'spaces'            => 1,
                                       'total_instances'   => cc_app[:instances],
                                       'users'             => 1)
        end
      end

      context 'doppler cell' do
        let(:application_instance_source) { :doppler_cell }
        it 'retrieves' do
          expect(retrieved).to include('apps'              => 1,
                                       'cells'             => 1,
                                       'deas'              => 0,
                                       'organizations'     => 1,
                                       'running_instances' => cc_app[:instances],
                                       'spaces'            => 1,
                                       'total_instances'   => cc_app[:instances],
                                       'users'             => 1)
        end
      end

      context 'doppler dea' do
        let(:application_instance_source) { :doppler_dea }
        it 'retrieves' do
          expect(retrieved).to include('apps'              => 1,
                                       'cells'             => 0,
                                       'deas'              => 1,
                                       'organizations'     => 1,
                                       'running_instances' => cc_app[:instances],
                                       'spaces'            => 1,
                                       'total_instances'   => cc_app[:instances],
                                       'users'             => 1)
        end
      end
    end

    shared_examples 'deas_view_model' do
      let(:path)              { '/deas_view_model' }
      let(:view_model_source) { view_models_deas }
      it_behaves_like('retrieves view_model')
    end

    shared_examples 'deas_view_model_detail' do
      let(:view_model_source) { view_models_deas_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'varz deas_view_model' do
      it_behaves_like('deas_view_model')
    end

    context 'varz deas_view_model_detail' do
      let(:path) { "/deas_view_model/#{nats_dea['host']}" }
      it_behaves_like('deas_view_model_detail')
    end

    context 'doppler deas_view_model' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('deas_view_model')
    end

    context 'doppler deas_view_model_detail' do
      let(:application_instance_source) { :doppler_dea }
      let(:path)                        { "/deas_view_model/#{dea_envelope.ip}:#{dea_envelope.index}" }
      it_behaves_like('deas_view_model_detail')
    end

    context 'domains_view_model' do
      let(:path)              { '/domains_view_model' }
      let(:view_model_source) { view_models_domains }
      it_behaves_like('retrieves view_model')
    end

    context 'domains_view_model detail' do
      let(:path)              { "/domains_view_model/#{cc_domain[:guid]}" }
      let(:view_model_source) { view_models_domains_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'download' do
      let(:response) { get_response("/download?path=#{log_file_displayed}") }
      it 'retrieves' do
        body = response.body
        expect(body).to eq(log_file_displayed_contents)
      end
    end

    context 'events_view_model' do
      let(:path)              { '/events_view_model' }
      let(:view_model_source) { view_models_events }
      it_behaves_like('retrieves view_model')
    end

    context 'events_view_model detail' do
      let(:path)              { "/events_view_model/#{cc_event_space[:guid]}" }
      let(:view_model_source) { view_models_events_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'feature_flags_view_model' do
      let(:path)              { '/feature_flags_view_model' }
      let(:view_model_source) { view_models_feature_flags }
      it_behaves_like('retrieves view_model')
    end

    context 'feature_flags_view_model detail' do
      let(:path)              { "/feature_flags_view_model/#{cc_feature_flag[:name]}" }
      let(:view_model_source) { view_models_feature_flags_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'gateways_view_model' do
      let(:path)              { '/gateways_view_model' }
      let(:view_model_source) { view_models_gateways }
      it_behaves_like('retrieves view_model')
    end

    context 'gateways_view_model detail' do
      let(:path)              { "/gateways_view_model/#{nats_provisioner['type'].sub('-Provisioner', '')}" }
      let(:view_model_source) { view_models_gateways_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'groups_view_model' do
      let(:path)              { '/groups_view_model' }
      let(:view_model_source) { view_models_groups }
      it_behaves_like('retrieves view_model')
    end

    context 'groups_view_model detail' do
      let(:path)              { "/groups_view_model/#{uaa_group[:id]}" }
      let(:view_model_source) { view_models_groups_detail }
      it_behaves_like('retrieves view_model detail')
    end

    shared_examples 'health_managers_view_model' do
      let(:path)              { '/health_managers_view_model' }
      let(:view_model_source) { view_models_health_managers }
      it_behaves_like('retrieves view_model')
    end

    shared_examples 'health_managers_view_model detail' do
      let(:view_model_source) { view_models_health_managers_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'varz health_managers_view_model' do
      it_behaves_like('health_managers_view_model')
    end

    context 'varz health_managers_view_model detail' do
      let(:path) { "/health_managers_view_model/#{nats_health_manager['host']}" }
      it_behaves_like('health_managers_view_model detail')
    end

    context 'doppler health_managers_view_model' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('health_managers_view_model')
    end

    context 'doppler health_managers_view_model detail' do
      let(:application_instance_source) { :doppler_dea }
      let(:path)                        { "/health_managers_view_model/#{analyzer_envelope.ip}:#{analyzer_envelope.index}" }
      it_behaves_like('health_managers_view_model detail')
    end

    context 'identity_providers_view_model' do
      let(:path)              { '/identity_providers_view_model' }
      let(:view_model_source) { view_models_identity_providers }
      it_behaves_like('retrieves view_model')
    end

    context 'identity_providers_view_model detail' do
      let(:path)              { "/identity_providers_view_model/#{uaa_identity_provider[:id]}" }
      let(:view_model_source) { view_models_identity_providers_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'identity_zones_view_model' do
      let(:path)              { '/identity_zones_view_model' }
      let(:view_model_source) { view_models_identity_zones }
      it_behaves_like('retrieves view_model')
    end

    context 'identity_zones_view_model detail' do
      let(:path)              { "/identity_zones_view_model/#{uaa_identity_zone[:id]}" }
      let(:view_model_source) { view_models_identity_zones_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'log' do
      let(:retrieved) { get_json("/log?path=#{log_file_displayed}", true) }
      it 'retrieves' do
        expect(retrieved).to include('data'      => log_file_displayed_contents,
                                     'file_size' => log_file_displayed_contents_length,
                                     'page_size' => log_file_page_size,
                                     'path'      => log_file_displayed,
                                     'read_size' => log_file_displayed_contents_length,
                                     'start'     => 0)
      end
    end

    context 'logs_view_model' do
      let(:path)              { '/logs_view_model' }
      let(:view_model_source) { view_models_logs(log_file_displayed, log_file_displayed_contents_length, log_file_displayed_modified_milliseconds) }
      it_behaves_like('retrieves view_model')
    end

    shared_examples 'organizations' do
      context 'organizations_view_model' do
        let(:path)              { '/organizations_view_model' }
        let(:view_model_source) { view_models_organizations }
        it_behaves_like('retrieves view_model')
      end

      context 'organizations_view_model detail' do
        let(:path)              { "/organizations_view_model/#{cc_organization[:guid]}" }
        let(:view_model_source) { view_models_organizations_detail }
        it_behaves_like('retrieves view_model detail')
      end
    end

    context 'varz dea' do
      it_behaves_like('organizations')
    end

    context 'doppler cell' do
      let(:application_instance_source) { :doppler_cell }
      it_behaves_like('organizations')
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('organizations')
    end

    context 'organization_roles_view_model' do
      let(:path)              { '/organization_roles_view_model' }
      let(:view_model_source) { view_models_organization_roles }
      it_behaves_like('retrieves view_model')
    end

    context 'organization_roles_view_model detail' do
      let(:path)              { "/organization_roles_view_model/#{cc_organization[:guid]}/auditors/#{cc_user[:guid]}" }
      let(:view_model_source) { view_models_organization_roles_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'quotas_view_model' do
      let(:path)              { '/quotas_view_model' }
      let(:view_model_source) { view_models_quotas }
      it_behaves_like('retrieves view_model')
    end

    context 'quotas_view_model detail' do
      let(:path)              { "/quotas_view_model/#{cc_quota_definition[:guid]}" }
      let(:view_model_source) { view_models_quotas_detail }
      it_behaves_like('retrieves view_model detail')
    end

    shared_examples 'routers_view_model' do
      let(:path)              { '/routers_view_model' }
      let(:view_model_source) { view_models_routers }
      it_behaves_like('retrieves view_model')
    end

    shared_examples 'routers_view_model detail' do
      let(:view_model_source) { view_models_routers_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'varz routers_view_model' do
      it_behaves_like('routers_view_model')
    end

    context 'varz routers_view_model detail' do
      let(:path) { "/routers_view_model/#{nats_router['host']}" }
      it_behaves_like('routers_view_model detail')
    end

    context 'doppler routers_view_model' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('routers_view_model')
    end

    context 'doppler routers_view_model detail' do
      let(:application_instance_source) { :doppler_dea }
      let(:path)                        { "/routers_view_model/#{gorouter_envelope.ip}:#{gorouter_envelope.index}" }
      it_behaves_like('routers_view_model detail')
    end

    context 'routes_view_model' do
      let(:event_type)        { 'route' }
      let(:path)              { '/routes_view_model' }
      let(:view_model_source) { view_models_routes }
      it_behaves_like('retrieves view_model')
    end

    context 'routes_view_model detail' do
      let(:path)              { "/routes_view_model/#{cc_route[:guid]}" }
      let(:view_model_source) { view_models_routes_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'security_groups_spaces_view_model' do
      let(:path)              { '/security_groups_spaces_view_model' }
      let(:view_model_source) { view_models_security_groups_spaces }
      it_behaves_like('retrieves view_model')
    end

    context 'security_groups_spaces_view_model detail' do
      let(:path)              { "/security_groups_spaces_view_model/#{cc_security_group[:guid]}/#{cc_space[:guid]}" }
      let(:view_model_source) { view_models_security_groups_spaces_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'security_groups_view_model' do
      let(:path)              { '/security_groups_view_model' }
      let(:view_model_source) { view_models_security_groups }
      it_behaves_like('retrieves view_model')
    end

    context 'security_groups_view_model detail' do
      let(:path)              { "/security_groups_view_model/#{cc_security_group[:guid]}" }
      let(:view_model_source) { view_models_security_groups_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_bindings_view_model' do
      let(:event_type)        { 'service_binding' }
      let(:path)              { '/service_bindings_view_model' }
      let(:view_model_source) { view_models_service_bindings }
      it_behaves_like('retrieves view_model')
    end

    context 'service_bindings_view_model detail' do
      let(:path)              { "/service_bindings_view_model/#{cc_service_binding[:guid]}" }
      let(:view_model_source) { view_models_service_bindings_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_brokers_view_model' do
      let(:event_type)        { 'service_broker' }
      let(:path)              { '/service_brokers_view_model' }
      let(:view_model_source) { view_models_service_brokers }
      it_behaves_like('retrieves view_model')
    end

    context 'service_brokers_view_model detail' do
      let(:path)              { "/service_brokers_view_model/#{cc_service_broker[:guid]}" }
      let(:view_model_source) { view_models_service_brokers_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_instances_view_model' do
      let(:event_type)        { 'service_instance' }
      let(:path)              { '/service_instances_view_model' }
      let(:view_model_source) { view_models_service_instances }
      it_behaves_like('retrieves view_model')
    end

    context 'service_instances_view_model detail' do
      let(:path)              { "/service_instances_view_model/#{cc_service_instance[:guid]}" }
      let(:view_model_source) { view_models_service_instances_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_keys_view_model' do
      let(:event_type)        { 'service_key' }
      let(:path)              { '/service_keys_view_model' }
      let(:view_model_source) { view_models_service_keys }
      it_behaves_like('retrieves view_model')
    end

    context 'service_keys_view_model detail' do
      let(:path)              { "/service_keys_view_model/#{cc_service_key[:guid]}" }
      let(:view_model_source) { view_models_service_keys_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_plans_view_model' do
      let(:event_type)        { 'service_plan' }
      let(:path)              { '/service_plans_view_model' }
      let(:view_model_source) { view_models_service_plans }
      it_behaves_like('retrieves view_model')
    end

    context 'service_plans_view_model detail' do
      let(:path)              { "/service_plans_view_model/#{cc_service_plan[:guid]}" }
      let(:view_model_source) { view_models_service_plans_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'service_plan_visibilities_view_model' do
      let(:event_type)        { 'service_plan_visibility' }
      let(:path)              { '/service_plan_visibilities_view_model' }
      let(:view_model_source) { view_models_service_plan_visibilities }
      it_behaves_like('retrieves view_model')
    end

    context 'service_plan_visibilities_view_model detail' do
      let(:path)              { "/service_plan_visibilities_view_model/#{cc_service_plan_visibility[:guid]}" }
      let(:view_model_source) { view_models_service_plan_visibilities_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'services_view_model' do
      let(:event_type)        { 'service' }
      let(:path)              { '/services_view_model' }
      let(:view_model_source) { view_models_services }
      it_behaves_like('retrieves view_model')
    end

    context 'services_view_model detail' do
      let(:path)              { "/services_view_model/#{cc_service[:guid]}" }
      let(:view_model_source) { view_models_services_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'settings' do
      let(:retrieved) { get_json('/settings') }
      it 'retrieves' do
        expect(retrieved).to eq('admin'                => true,
                                'build'                => '2222',
                                'cloud_controller_uri' => cloud_controller_uri,
                                'table_height'         => table_height,
                                'table_page_size'      => table_page_size,
                                'user'                 => LoginHelper::LOGIN_ADMIN)
      end
    end

    context 'space_quotas_view_model' do
      let(:path)              { '/space_quotas_view_model' }
      let(:view_model_source) { view_models_space_quotas }
      it_behaves_like('retrieves view_model')
    end

    context 'space_quotas_view_model detail' do
      let(:path)              { "/space_quotas_view_model/#{cc_space_quota_definition[:guid]}" }
      let(:view_model_source) { view_models_space_quotas_detail }
      it_behaves_like('retrieves view_model detail')
    end

    context 'space_roles_view_model' do
      let(:path)              { '/space_roles_view_model' }
      let(:view_model_source) { view_models_space_roles }
      it_behaves_like('retrieves view_model')
    end

    context 'space_roles_view_model detail' do
      let(:path)              { "/space_roles_view_model/#{cc_space[:guid]}/auditors/#{cc_user[:guid]}" }
      let(:view_model_source) { view_models_space_roles_detail }
      it_behaves_like('retrieves view_model detail')
    end

    shared_examples 'spaces' do
      context 'spaces_view_model' do
        let(:path)              { '/spaces_view_model' }
        let(:view_model_source) { view_models_spaces }
        it_behaves_like('retrieves view_model')
      end

      context 'spaces_view_model detail' do
        let(:path)              { "/spaces_view_model/#{cc_space[:guid]}" }
        let(:view_model_source) { view_models_spaces_detail }
        it_behaves_like('retrieves view_model detail')
      end
    end

    context 'varz dea' do
      it_behaves_like('spaces')
    end

    context 'doppler cell' do
      let(:application_instance_source) { :doppler_cell }
      it_behaves_like('spaces')
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('spaces')
    end

    context 'stacks_view_model' do
      let(:path)              { '/stacks_view_model' }
      let(:view_model_source) { view_models_stacks }
      it_behaves_like('retrieves view_model')
    end

    context 'stacks_view_model detail' do
      let(:path)              { "/stacks_view_model/#{cc_stack[:guid]}" }
      let(:view_model_source) { view_models_stacks_detail }
      it_behaves_like('retrieves view_model detail')
    end

    shared_examples 'stats_view_model' do
      let(:path)                        { '/stats_view_model' }
      let(:timestamp)                   { retrieved['items']['items'][0][9]['timestamp'] } # We have to copy the timestamp from the result since it is variable
      let(:view_model_source)           { view_models_stats(timestamp) }
      it_behaves_like('retrieves view_model')
    end

    context 'varz dea' do
      it_behaves_like('stats_view_model')
    end

    context 'doppler cell' do
      let(:application_instance_source) { :doppler_cell }
      it_behaves_like('stats_view_model')
    end

    context 'doppler dea' do
      let(:application_instance_source) { :doppler_dea }
      it_behaves_like('stats_view_model')
    end

    context 'users_view_model' do
      let(:path)              { '/users_view_model' }
      let(:view_model_source) { view_models_users }
      it_behaves_like('retrieves view_model')
    end

    context 'users_view_model detail' do
      let(:path)              { "/users_view_model/#{cc_user[:guid]}" }
      let(:view_model_source) { view_models_users_detail }
      it_behaves_like('retrieves view_model detail')
    end
  end
end
