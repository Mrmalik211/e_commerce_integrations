require 'shippo'

require 'net/http'
require 'uri'
require 'json'

class Ship

  def initialize(user_id = nil)
    @user = User.find(user_id)
    Shippo::API.token = ENV['SHIPPO_TOKEN']
  end

  def create_shipment(order, package)
    box = package.box

    phone = order.phone.present? ? order.phone : ENV['DEFAULT_PHONE']

    address_from = if order.location.state == MD
      {
        name: @user.warehouse_name,
        street1: '350 Winmeyer Avenue, Suite B',
        city: 'Odenton',
        state: MD,
        zip: '21113',
        country: 'US',
        phone: '1234567890'
      }
    else
      {
        name: @user.warehouse_name,
        street1: '1566 S Archibald Ave',
        city: 'Ontario',
        state: CA,
        zip: '91761',
        country: 'US',
        phone: '1234567890'
      }
    end

    uri = URI.parse('https://api.goshippo.com/shipments/')
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request['Authorization'] = "ShippoToken #{ENV['SHIPPO_TOKEN']}"

    request.body = JSON.dump({
      'address_from': address_from,
      'address_to': {
        'name': order.name,
        'street1': "#{order.street} #{order.apt_number}",
        'city': order.city,
        'state': order.state,
        'zip': order.zip,
        'country': 'US',
        'phone': phone
      },
      'parcels': [
        {
          'length': box.length,
          'width': box.width,
          'height': box.height,
          'distance_unit': 'in',
          'weight': package.weight,
          'mass_unit': 'lb'
        }
      ],
      'async': false
    })

    req_options = {
      use_ssl: uri.scheme == 'https'
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    response = HashWithIndifferentAccess.new(JSON.parse(response.body).to_hash)
  end

  def validate_address(name, street, city, state, zip, country)
    uri = URI.parse('https://api.goshippo.com/addresses/')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "ShippoToken #{ENV['SHIPPO_TOKEN']}"
    request.body = "name=#{name}&street1=#{street}&city=#{city}&state=#{state}&zip=#{zip}&country=#{country}&validate=true"

    req_options = { use_ssl: uri.scheme == 'https' }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end
    HashWithIndifferentAccess.new(JSON.parse(response.body).to_hash)
  end

  def create_custom_shipment(label, package, return_shipment = false, vendor_shipment = false)
    box = package.box
    ship_to_phone = label.ship_to_phone.present? ? label.ship_to_phone : '2409204800'
    address_to = {
      name: label.ship_to_name,
      street1: "#{label.ship_to_street} #{label.ship_to_apt_number}",
      city: label.ship_to_city,
      state: label.ship_to_state,
      zip: label.ship_to_zip,
      phone: ship_to_phone,
      country: label.ship_to_country,
      is_residential: true
    }
    if vendor_shipment
      vendor = User.find label.vendor_id
      address_from = {
        name: vendor.ship_from_name,
        street1: "#{vendor.ship_from_street} #{vendor.ship_from_apt_number}",
        city: vendor.ship_from_city,
        state: vendor.ship_from_state,
        zip: vendor.ship_from_zip,
        phone: vendor.ship_from_phone,
        country: vendor.ship_from_country,
      }
    else
      phone = label.ship_from_phone.present? ? label.ship_from_phone : ENV['DEFAULT_PHONE']
      address_from = {
        name: label.ship_from_name,
        street1: "#{label.ship_from_street} #{label.ship_from_apt_number}",
        city: label.ship_from_city,
        state: label.ship_from_state,
        zip: label.ship_from_zip,
        phone: phone,
        country: label.ship_from_country
      }
    end

    parcel = {
      length: box.length,
      width: box.width,
      height: box.height,
      distance_unit: :in,
      weight: package.weight,
      mass_unit: :lb
    }

    obj = {
      'address_from': address_from,
      'address_to': address_to,
      'parcels': [
          parcel
      ],
      'async': false
    }

    obj['extra'] = { is_return: true } if return_shipment
    
    uri = URI.parse('https://api.goshippo.com/shipments/')
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request['Authorization'] = "ShippoToken #{ENV['SHIPPO_TOKEN']}"

    request.body = JSON.dump(obj)

    req_options = {
      use_ssl: uri.scheme == 'https'
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    HashWithIndifferentAccess.new(JSON.parse(response.body).to_hash)
  end

  def create_transaction(rate_object_id)
    uri = URI.parse('https://api.goshippo.com/transactions')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "ShippoToken #{ENV['SHIPPO_TOKEN']}"
    request.set_form_data(
      'async': false,
      'label_file_type': 'PDF_4x6',
      'rate': rate_object_id
    )

    req_options = {
      use_ssl: uri.scheme == 'https'
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end
    
    transaction = HashWithIndifferentAccess.new(JSON.parse(response.body).to_hash)
    if transaction[:status] == 'SUCCESS'
      puts "label_url: #{transaction[:label_url]}"
      puts "tracking_number: #{transaction[:tracking_number]}"
    else
      puts 'Error generating label:'
      puts transaction[:messages]
    end

    transaction
  end
end
