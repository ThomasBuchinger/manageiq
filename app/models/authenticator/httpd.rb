module Authenticator
  class Httpd < Base
    def self.proper_name
      'External httpd'
    end

    def authorize_queue(username, request, options, *_args)
      user_attrs, membership_list =
        if options[:authorize_only]
          user_details_from_external_directory(username)
        else
          user_details_from_headers(username, request)
        end

      super(username, request, {}, user_attrs, membership_list)
    end

    # We don't talk to an external system in #find_external_identity /
    # #groups_for, so no need to enqueue the work
    def authorize_queue?
      false
    end

    def user_authorizable_without_authentication?
      true
    end

    def _authenticate(_username, _password, request)
      request.present? &&
        request.headers['X-REMOTE-USER'].present?
    end

    def failure_reason(_username, request)
      request.headers['X-EXTERNAL-AUTH-ERROR']
    end

    def find_external_identity(_username, user_attrs, membership_list)
      [user_attrs, membership_list]
    end

    def groups_for(identity)
      _user_attrs, membership_list = identity
      MiqGroup.strip_group_domains(membership_list)
    end

    def update_user_attributes(user, username, identity)
      user_attrs, _membership_list = identity

      user.userid     = username
      user.first_name = user_attrs[:firstname]
      user.last_name  = user_attrs[:lastname]
      user.email      = user_attrs[:email] unless user_attrs[:email].blank?
      user.name       = user_attrs[:fullname]
      user.name       = "#{user.first_name} #{user.last_name}" if user.name.blank?
      user.name       = user.userid if user.name.blank?
    end

    def find_or_initialize_user(identity, username)
      user_attrs, _membership_list = identity
      return super if user_attrs[:domain].nil?

      upn_username = "#{user_attrs[:username]}@#{user_attrs[:domain]}".downcase

      user = find_userid_as_upn(upn_username)
      user ||= find_userid_as_distinguished_name(user_attrs, upn_username)
      user ||= find_userid_as_username(identity, username, upn_username)
      user ||= User.new(:userid => upn_username)

      [upn_username, user]
    end

    private

    def find_userid_as_upn(upn_username)
      user = User.find_by_userid(upn_username)
      user || User.in_my_region.where('lower(userid) = ?', upn_username).order(:lastlogon).last
    end

    def find_userid_as_username(identity, username, upn_username)
      userid = userid_for(identity, username)
      user   = User.find_by_userid(userid)
      user ||= User.in_my_region.where('lower(userid) = ?', userid).order(:lastlogon).last
      $audit_log.info("Updating userid from #{user.userid} to #{upn_username}") unless user.blank?

      user
    end

    def find_userid_as_distinguished_name(user_attrs, upn_username)
      dn_domain = user_attrs[:domain].downcase.split(".").map { |s| "dc=#{s}" }.join(",")
      user = User.in_my_region.where("userid LIKE ?", "%=#{user_attrs[:username]},%,#{dn_domain}").last
      $audit_log.info("Updating userid from #{user.userid} to #{upn_username}") unless user.blank?

      user
    end

    def user_details_from_external_directory(username)
      ext_user_attrs = user_attrs_from_external_directory(username)
      user_attrs = {:username  => username,
                    :fullname  => ext_user_attrs["displayname"],
                    :firstname => ext_user_attrs["givenname"],
                    :lastname  => ext_user_attrs["sn"],
                    :email     => ext_user_attrs["mail"],
                    :domain    => ext_user_attrs["domainname"]}
      [user_attrs, MiqGroup.get_httpd_groups_by_user(username)]
    end

    def user_details_from_headers(username, request)
      user_attrs = {:username  => username,
                    :fullname  => request.headers['X-REMOTE-USER-FULLNAME'],
                    :firstname => request.headers['X-REMOTE-USER-FIRSTNAME'],
                    :lastname  => request.headers['X-REMOTE-USER-LASTNAME'],
                    :email     => request.headers['X-REMOTE-USER-EMAIL'],
                    :domain    => request.headers['X-REMOTE-USER-DOMAIN']}
      [user_attrs, (request.headers['X-REMOTE-USER-GROUPS'] || '').split(/[;:]/)]
    end

    def user_attrs_from_external_directory(username)
      return unless username
      require "dbus"

      attrs_needed = %w(mail givenname sn displayname domainname)

      sysbus = DBus.system_bus
      ifp_service   = sysbus["org.freedesktop.sssd.infopipe"]
      ifp_object    = ifp_service.object "/org/freedesktop/sssd/infopipe"
      ifp_object.introspect
      ifp_interface = ifp_object["org.freedesktop.sssd.infopipe"]
      begin
        user_attrs = ifp_interface.GetUserAttr(username, attrs_needed).first
      rescue => err
        raise _("Unable to get attributes for external user %{user_name} - %{error}") %
              {:user_name => username, :error => err}
      end

      attrs_needed.each_with_object({}) { |attr, hash| hash[attr] = Array(user_attrs[attr]).first }
    end
  end
end
