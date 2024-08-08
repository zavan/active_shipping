module ActiveShipping
  class USPSRest < Carrier
    EventDetails = Struct.new(:description, :time, :zoneless_time, :location, :event_code)
    ONLY_PREFIX_EVENTS = ['DELIVERED','OUT FOR DELIVERY']
    self.retry_safe = true
    self.ssl_version = :TLSv1_2

    cattr_reader :name
    @@name = "USPS"

    LIVE_DOMAIN = 'production.shippingapis.com'
    LIVE_RESOURCE = 'ShippingAPI.dll'

    TEST_DOMAINS = { # indexed by security; e.g. TEST_DOMAINS[USE_SSL[:rates]]
      true => 'secure.shippingapis.com',
      false => 'stg-production.shippingapis.com'
    }

    MAIL_TYPES = {
      :package => 'Package',
      :postcard => 'Postcards or aerogrammes',
      :matter_for_the_blind => 'Matter for the blind',
      :envelope => 'Envelope'
    }

    PACKAGE_PROPERTIES = {
      'ZipOrigination' => :origin_zip,
      'ZipDestination' => :destination_zip,
      'Pounds' => :pounds,
      'Ounces' => :ounces,
      'Container' => :container,
      'Size' => :size,
      'Machinable' => :machinable,
      'Zone' => :zone,
      'Postage' => :postage,
      'Restrictions' => :restrictions
    }
    POSTAGE_PROPERTIES = {
      'MailService' => :service,
      'Rate' => :rate
    }

    US_SERVICES = {
      :first_class => 'FIRST CLASS',
      :priority => 'PRIORITY',
      :express => 'EXPRESS',
      :bpm => 'BPM',
      :parcel => 'PARCEL',
      :media => 'MEDIA',
      :library => 'LIBRARY',
      :online => 'ONLINE',
      :plus => 'PLUS',
      :all => 'ALL'
    }

    ESCAPING_AND_SYMBOLS = /&lt;\S*&gt;/
    LEADING_USPS = /^USPS /
    TRAILING_ASTERISKS = /\*+$/
    SERVICE_NAME_SUBSTITUTIONS = /#{ESCAPING_AND_SYMBOLS}|#{LEADING_USPS}|#{TRAILING_ASTERISKS}/

    # Array of U.S. possessions according to USPS: https://www.usps.com/ship/official-abbreviations.htm
    US_POSSESSIONS = %w(AS FM GU MH MP PW PR VI)

    # Country names:
    # http://pe.usps.gov/text/Imm/immctry.htm
    COUNTRY_NAME_CONVERSIONS = {
      "BA" => "Bosnia-Herzegovina",
      "CD" => "Congo, Democratic Republic of the",
      "CG" => "Congo (Brazzaville),Republic of the",
      "CI" => "Côte d'Ivoire (Ivory Coast)",
      "CK" => "Cook Islands (New Zealand)",
      "FK" => "Falkland Islands",
      "GB" => "Great Britain and Northern Ireland",
      "GE" => "Georgia, Republic of",
      "IR" => "Iran",
      "KN" => "Saint Kitts (St. Christopher and Nevis)",
      "KP" => "North Korea (Korea, Democratic People's Republic of)",
      "KR" => "South Korea (Korea, Republic of)",
      "LA" => "Laos",
      "LY" => "Libya",
      "MC" => "Monaco (France)",
      "MD" => "Moldova",
      "MK" => "Macedonia, Republic of",
      "MM" => "Burma",
      "PN" => "Pitcairn Island",
      "RU" => "Russia",
      "SK" => "Slovak Republic",
      "TK" => "Tokelau (Union) Group (Western Samoa)",
      "TW" => "Taiwan",
      "TZ" => "Tanzania",
      "VA" => "Vatican City",
      "VG" => "British Virgin Islands",
      "VN" => "Vietnam",
      "WF" => "Wallis and Futuna Islands",
      "WS" => "Western Samoa"
    }

       SERVICE_TYPES = [
        "PARCEL_SELECT",
        "PARCEL_SELECT_LIGHTWEIGHT",
        "PRIORITY_MAIL_EXPRESS",
        "PRIORITY_MAIL",
        "FIRST-CLASS_PACKAGE_SERVICE",
        "LIBRARY_MAIL",
        "MEDIA_MAIL",
        "BOUND_PRINTED_MATTER",
        "USPS_CONNECT_LOCAL",
        "USPS_CONNECT_MAIL",
        "USPS_CONNECT_NEXT_DAY",
        "USPS_CONNECT_REGIONAL",
        "USPS_CONNECT_SAME_DAY",
        "USPS_GROUND_ADVANTAGE",
        "USPS_RETAIL_GROUND",
      ]

    def requirements
      [:client_id, :client_secret, :access_token]
    end

    def find_rates(origin, destination, packages, options = {})
      # raise "from USPSRest here origin: #{origin} and destination: #{destination} and packages: #{packages} and options: #{options}"

      options = @options.merge(options)

      origin = Location.from(origin)
      destination = Location.from(destination)
      packages = Array(packages)

      domestic_codes = US_POSSESSIONS + ['US', nil]
      if domestic_codes.include?(destination.country_code(:alpha2))
        us_rates(origin, destination, packages, options)
      else
        world_rates(origin, destination, packages, options)
      end
    end

    def us_rates(origin, destination, packages, options = {})
      # raise "widht: #{packages.first.inches(:width)} / dimentions: #{packages.first} / weigth: #{packages.first.weight} packages: #{packages} / count: #{packages.count}".inspect
      success = true
      message = ''

      body = {
        originZIPCode: origin.zip,
        destinationZIPCode: destination.zip,
        weight: 6.0,
        length: 20.0,
        width: 20.0,
        height: 5.0,
      }

      request = http_request(
        "https://api-cat.usps.com/prices/v3/total-rates/search",
        body.to_json,
      )

      response = JSON.parse(request)

      if response["rateOptions"]
        rate_estimates = package_rate_estimates(origin, destination, packages, response, options = {})
      else
        success = false
        message = "An error occured. Please try again."
      end

      raise "rate_estimates #{rate_estimates}".inspect
      RateResponse.new(success, message, response, :rates => rate_estimates)
    end

    protected

    def package_rate_estimates(origin, destination, packages, response, options = {})
      SERVICE_TYPES.map do |service_type|
        rates = response["rateOptions"].select do |option|
          option["rates"].any? { |rate| rate["mailClass"] == service_type }
        end

        next if rates.nil? || rates.empty?

        min_price_option = rates.min_by do |option|
          option["rates"].map { |rate| rate["price"] }.min
        end
        service_rate = min_price_option["rates"].first

        if service_rate.nil?
          raise "service_type #{service_type}".inspect
        end

        service_rate
        # RateEstimate.new(origin, destination, @@name, service_rate["mailClass"],
        #   :service_code => service_rate["mailClass"],
        #   :total_price => service_rate["price"],
        #   :currency => "USD",
        #   :packages => packages
        # )
      end
    end

    # def parse_rate_response(origin, destination, packages, response, options = {})
    #   success = true
    #   message = ''
    #   rate_hash = {}

    #   if response["totalBasePrice"]
    #     rate_estimates = response["rates"].map do |rate|
    #       RateEstimate.new(origin, destination, @@name, service_name_for_code(rate["mailClass"]),
    #         :service_code => rate["mailClass"],
    #         :total_price => rate["price"],
    #         :currency => "USD",
    #         :packages => packages,
    #       )
    #     end

    #     rate_estimates.reject! { |e| e.package_count != packages.length }
    #     rate_estimates = rate_estimates.sort_by(&:total_price)
    #   else
    #     success = false
    #     message = "An error occured. Please try again."
    #   end

    #   RateResponse.new(success, message, response, rates: rate_estimates)
    # end

    private

    def service_name_for_code(service_code)
      SERVICE_TYPES[service_code] || service_name_for(service_code)
    end

    def service_name_for(code)
      formatted_name = code.gsub('_', ' ')
      formatted_name = formatted_name.split.map.with_index do |word, index|
        index == 0 && word.upcase == "USPS" ? word.upcase : word.capitalize
      end.join(' ')

      formatted_name
    end

    def http_request(full_url, body)
      headers = {
        "Authorization" => "Bearer #{@options[:access_token]}",
        "Content-type" => "application/json"
      }

      ssl_post(full_url, body, headers)
    end
  end
end
