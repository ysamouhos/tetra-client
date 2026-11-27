# App Store distribution signing through the App Store Connect API, without
# Xcode's automatic signing.
#
#   ruby asc_signing.rb setup    creates a temporary distribution certificate,
#                                App Store profiles for the app + widget, and
#                                writes the key, cert and profiles to $OUT
#   ruby asc_signing.rb cleanup  revokes that certificate and deletes the profiles
#
# Env: KEY_ID, ISSUER, KEY_PATH (.p8), BUNDLE_ID, OUT (work dir).
# Revoking the certificate afterwards does not affect builds already uploaded.
require 'openssl'
require 'base64'
require 'json'
require 'net/http'
require 'fileutils'

def fail!(msg)
  puts "::error::#{msg}"
  exit 1
end

KEY_ID = ENV.fetch('KEY_ID')
ISSUER = ENV.fetch('ISSUER')
OUT = ENV.fetch('OUT')
STATE = File.join(OUT, 'asc_state.json')
FileUtils.mkdir_p(OUT)

def jwt
  key = OpenSSL::PKey.read(File.read(ENV.fetch('KEY_PATH')))
  b64 = ->(s) { Base64.urlsafe_encode64(s, padding: false) }
  now = Time.now.to_i
  input = b64.(JSON.generate(alg: 'ES256', kid: KEY_ID, typ: 'JWT')) + '.' +
          b64.(JSON.generate(iss: ISSUER, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1'))
  der = key.sign(OpenSSL::Digest::SHA256.new, input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\0")[-32, 32] }
  "#{input}.#{b64.(r + s)}"
end

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{jwt}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(body) if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  data = res.body.to_s.empty? ? {} : (JSON.parse(res.body) rescue { 'raw' => res.body })
  [res.code.to_i, data]
end

def errors(data)
  (data['errors'] || []).map { |e| "#{e['code']}: #{e['detail']}" }.join(' | ')
end

def bundle_resource(identifier, name)
  code, data = api(:get, "/v1/bundleIds?filter[identifier]=#{URI.encode_www_form_component(identifier)}&limit=10")
  fail!("Listing bundle IDs failed (HTTP #{code}): #{errors(data)}") unless code == 200
  found = data['data'].find { |d| d.dig('attributes', 'identifier') == identifier }
  return found['id'] if found
  code, data = api(:post, '/v1/bundleIds', { data: { type: 'bundleIds',
    attributes: { identifier: identifier, name: name, platform: 'IOS' } } })
  fail!("Registering bundle ID #{identifier} failed (HTTP #{code}): #{errors(data)}") unless code == 201
  data['data']['id']
end

def enable_app_groups(bundle_res_id, identifier)
  code, data = api(:post, '/v1/bundleIdCapabilities', { data: { type: 'bundleIdCapabilities',
    attributes: { capabilityType: 'APP_GROUPS' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: bundle_res_id } } } } })
  return if code == 201 || code == 409 # 409: already enabled
  puts "::warning::Could not enable App Groups on #{identifier} (HTTP #{code}): #{errors(data)}"
end

def setup
  base = ENV.fetch('BUNDLE_ID')
  tag = "gh-#{ENV.fetch('GITHUB_RUN_ID', Time.now.to_i.to_s)}"
  state = { 'profiles' => [] }

  # 1. Temporary distribution certificate from a fresh key + CSR.
  rsa = OpenSSL::PKey::RSA.new(2048)
  csr = OpenSSL::X509::Request.new
  csr.version = 0
  csr.subject = OpenSSL::X509::Name.new([['CN', "TestFlight CI #{tag}"]])
  csr.public_key = rsa.public_key
  csr.sign(rsa, OpenSSL::Digest::SHA256.new)
  code, data = api(:post, '/v1/certificates', { data: { type: 'certificates',
    attributes: { certificateType: 'DISTRIBUTION', csrContent: csr.to_pem } } })
  if code != 201
    hint = errors(data) =~ /maximum|limit|already have/i ?
      ' Your team has reached its distribution certificate limit: revoke an unused one under Certificates on developer.apple.com.' : ''
    fail!("Creating the distribution certificate failed (HTTP #{code}): #{errors(data)}.#{hint}")
  end
  state['certificate'] = data['data']['id']
  File.write(STATE, JSON.generate(state))
  cert = OpenSSL::X509::Certificate.new(Base64.decode64(data['data']['attributes']['certificateContent']))
  # Key and certificate as separate files: macOS `security import` cannot read
  # the PKCS#12 that OpenSSL 3 writes by default.
  File.write(File.join(OUT, 'dist_key.pem'), rsa.to_pem, perm: 0o600)
  File.binwrite(File.join(OUT, 'dist.cer'), cert.to_der)
  puts "Created distribution certificate #{cert.subject} (serial #{cert.serial.to_s(16)})."

  # 2. App Store profiles for the app and the widget extension.
  env = []
  [[base, 'TETRA Terminal', 'APP'], ["#{base}.TetraWidgets", 'TETRA Terminal Widgets', 'WIDGET']].each do |identifier, name, key|
    res_id = bundle_resource(identifier, name)
    enable_app_groups(res_id, identifier)
    profile_name = "#{identifier}-appstore-#{tag}"
    code, data = api(:post, '/v1/profiles', { data: { type: 'profiles',
      attributes: { name: profile_name, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: res_id } },
        certificates: { data: [{ type: 'certificates', id: state['certificate'] }] } } } })
    fail!("Creating the profile for #{identifier} failed (HTTP #{code}): #{errors(data)}") unless code == 201
    state['profiles'] << data['data']['id']
    File.write(STATE, JSON.generate(state))
    path = File.join(OUT, "#{key.downcase}.mobileprovision")
    File.binwrite(path, Base64.decode64(data['data']['attributes']['profileContent']))
    env << "#{key}_PROFILE_NAME=#{profile_name}" << "#{key}_PROFILE_PATH=#{path}"
    puts "Created profile '#{profile_name}'."
  end
  File.write(File.join(OUT, 'signing.env'), env.join("\n") + "\n")
end

def cleanup
  return puts('Nothing to clean up.') unless File.exist?(STATE)
  state = JSON.parse(File.read(STATE))
  state['profiles'].each do |id|
    code, data = api(:delete, "/v1/profiles/#{id}")
    puts(code == 204 ? "Deleted profile #{id}." : "::warning::Deleting profile #{id} failed (HTTP #{code}): #{errors(data)}")
  end
  if (id = state['certificate'])
    code, data = api(:delete, "/v1/certificates/#{id}")
    puts(code == 204 ? "Revoked certificate #{id}." : "::warning::Revoking certificate #{id} failed (HTTP #{code}): #{errors(data)}")
  end
  File.delete(STATE)
end

case ARGV[0]
when 'setup' then setup
when 'cleanup' then cleanup
else abort 'usage: asc_signing.rb setup|cleanup'
end
