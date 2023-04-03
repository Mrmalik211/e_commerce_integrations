class TrqService
  def initialize()
    @conn = Faraday.new(url: ENV['TRQ_API_URL'])
    @conn.headers = {
      'Content-Type': 'application/json'
    }
  end

  def init_token
    begin
      conn = Faraday.new(url: ENV['TRQ_TOKEN_URL'])
      response = conn.post('oauth2/v2.0/token') do |req|
        req.headers = {
          'Content-Type': 'application/x-www-form-urlencoded'
        }
        req.body = URI.encode_www_form({
          'client_id': ENV['TRQ_CLIENT_ID'],
          'scope': ENV['TRQ_SCOPE'],
          'username': ENV['TRQ_USER_NAME'],
          'password': ENV['TRQ_PASSWORD'],
          'grant_type': 'password',
          'response_type': 'token id_token'
        })
      end
      if response.status == 200
        response_body = JSON.parse(response.body, symbolize_names: true)
        @conn.headers['Authorization'] = "Bearer #{response_body[:id_token]}"
        return response_body[:id_token]
      else
        return 'authentication failed'
      end
    rescue Exception => e
      puts e.message, e.backtrace.join('\n')
    end
  end

  def get_cost ref_numbers, brand
    init_token
    request_details = {} 
    ref_numbers.split(',').map{ |i| request_details[i.split(':').first] =  i.split(':').second}
    response = @conn.post('parts/stock') do |req|
      req.body = request_details.keys.map{ |key| { sku: key, brandId: brand }}.to_json
    end
    if response.status == 200
      response_body = JSON.parse(response.body, symbolize_names: true)
      total_price = 0
      response_body.each do |r|
        return unless r[:stock] >= request_details[r[:sku]].to_i 
        total_price += r[:price]
      end
      total_price
    end
  end

  def push_order ref_numbers, order
    init_token
    begin
      order_parts = []
      ref_numbers.split(',').each do |r| 
        ref_list = r.split(':')
        order_parts.append({ sku: ref_list.first, quantity: ref_list.second, brandId: order.items.map{ |i| i.brand_items.find_by_part_number(ref_list.first) }.compact&.first&.brand&.name })
      end

      if Rails.env.production?
        body =  {
          poNumber: order.po_number,
          shippingMethod: get_shipping_method(order.shipping_method),
          shippingName: order.name,
          shippingAddress1: order.street,
          shippingAddress2: order.apt_number,
          shippingCity: order.city,
          shippingRegion: order.state,
          shippingPostalCode: order.zip,
          shippingCountry: "US",
          items: order_parts
        }
      else
        body =  {
          poNumber: 'FakeOrder23',
          shippingMethod: get_shipping_method(order.shipping_method),
          shippingName: order.name,
          shippingAddress1: order.street,
          shippingAddress2: order.apt_number,
          shippingCity: order.city,
          shippingRegion: order.state,
          shippingPostalCode: order.zip,
          shippingCountry: "US",
          items: order_parts,
          attributes: [{
              name: "dummy",
              value: "anything"
          }]
        }
      end
      response = @conn.post('orders') do |req|
        req.body = body.to_json
      end
      
      if response.status == 201
        ref_numbers.split(',').each do |item|
          part_number, qty, line_code = item.split ':'
          brand_items = BrandItem.where part_number: part_number
          brand_items.update_all inventory: (brand_items.first.inventory - qty.to_i)
        end
        order.update(pushed: true, items_pushed: true, pushed_to: "trq", status: 'processing')
        response.body
      end
    rescue Exception => e
      puts e.message, e.backtrace.join('\n')
    end
  end

  def fetch_tracking order_id
    init_token
    order = Order.find(order_id)
    response = @conn.get("orders/po/#{order.po_number}")
    if response.status == 200
      trackings = []
      response_body = JSON.parse(response.body, symbolize_names: true)
      response_body[:items].each do |i|
        if i[:trackingNumbers].present?
          i[:trackingNumbers].each do |t|
            order.trackings.create(number: t[:trackingNumber], carrier: t[:carrier])
          end
        end
      end
      PushTrackingJob.perform_later order_id
    end
  end
  
  private

  def get_shipping_method method
    if method == 'standard'
      'REGULAR'
    elsif method == 'second_day_air'
      'UPS 2ND DAY AIR'
    elsif method == 'next_day'
      'UPS NEXT DAY'
    end
  end
end
