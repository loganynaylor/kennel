# frozen_string_literal: true
# encapsulates knowledge around how the api works
# especially 1-off weirdness that should not lak into other parts of the code
module Kennel
  class Api
    CACHE_FILE = "tmp/cache/details"

    def initialize(app_key, api_key)
      @app_key = app_key
      @api_key = api_key
      @client = Faraday.new(url: "https://app.datadoghq.com") { |c| c.adapter :net_http_persistent }
    end

    def show(api_resource, id, params = {})
      response = request :get, "/api/v1/#{api_resource}/#{id}", params: params
      response = response.fetch(:data) if api_resource == "slo"
      response
    end

    def list(api_resource, params = {})
      with_pagination api_resource == "slo", params do |paginated_params|
        response = request :get, "/api/v1/#{api_resource}", params: paginated_params
        response = response.fetch(:dashboards) if api_resource == "dashboard"
        response = response.fetch(:data) if api_resource == "slo"
        response
      end
    end

    def create(api_resource, attributes)
      response = request :post, "/api/v1/#{api_resource}", body: attributes
      response = response.fetch(:data).first if api_resource == "slo"
      response
    end

    def update(api_resource, id, attributes)
      request :put, "/api/v1/#{api_resource}/#{id}", body: attributes
    end

    # - force=true to not dead-lock on dependent monitors+slos
    #   external dependency on kennel managed resources is their problem, we don't block on it
    #   (?force=true did not work, force for dashboard is not documented but does not blow up)
    def delete(api_resource, id)
      request :delete, "/api/v1/#{api_resource}/#{id}", params: { force: "true" }, ignore_404: true
    end

    def fill_details!(api_resource, list)
      details_cache do |cache|
        Utils.parallel(list) { |a| fill_detail!(api_resource, a, cache) }
      end
    end

    private

    def with_pagination(enabled, params)
      return yield params unless enabled
      raise ArgumentError if params[:limit] || params[:offset]
      limit = 1000
      offset = 0
      all = []

      loop do
        response = yield params.merge(limit: limit, offset: offset)
        all.concat response
        return all if response.size < limit
        offset += limit
      end
    end

    # Make diff work even though we cannot mass-fetch definitions
    def fill_detail!(api_resource, a, cache)
      args = [api_resource, a.fetch(:id)]
      full = cache.fetch(args, a.fetch(:modified_at)) { show(*args) }
      a.merge!(full)
    end

    def details_cache(&block)
      cache = FileCache.new CACHE_FILE, Kennel::VERSION
      cache.open(&block)
    end

    def request(method, path, body: nil, params: {}, ignore_404: false)
      path = "#{path}?#{Faraday::FlatParamsEncoder.encode(params)}" if params.any?
      with_cache ENV["FORCE_GET_CACHE"] && method == :get, path do
        response = nil
        tries = 2

        tries.times do |i|
          response = Utils.retry Faraday::ConnectionFailed, Faraday::TimeoutError, times: 2 do
            @client.send(method, path) do |request|
              request.body = JSON.generate(body) if body
              request.headers["Content-type"] = "application/json"
              request.headers["DD-API-KEY"] = @api_key
              request.headers["DD-APPLICATION-KEY"] = @app_key
            end
          end

          break if i == tries - 1 || method != :get || response.status < 500
          Kennel.err.puts "Retrying on server error #{response.status} for #{path}"
        end

        if !response.success? && (response.status != 404 || !ignore_404)
          message = +"Error #{response.status} during #{method.upcase} #{path}\n"
          message << "request:\n#{JSON.pretty_generate(body)}\nresponse:\n" if body
          message << response.body
          raise message
        end

        if response.body.empty?
          {}
        else
          JSON.parse(response.body, symbolize_names: true)
        end
      end
    end

    # allow caching all requests to speedup/benchmark logic that includes repeated requests
    def with_cache(enabled, key)
      return yield unless enabled
      dir = "tmp/cache"
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      file = "#{dir}/#{key.delete("/?=")}" # TODO: encode nicely
      if File.exist?(file)
        Marshal.load(File.read(file)) # rubocop:disable Security/MarshalLoad
      else
        result = yield
        File.write(file, Marshal.dump(result))
        result
      end
    end
  end
end
