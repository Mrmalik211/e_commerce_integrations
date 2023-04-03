class PartsAuthorityService
  def initialize
    @conn = Faraday.new(ENV['PARTS_URL'])
    @request_body = {
      accountNum: ENV['PARTS_ACCOUNT_NUM'],
      client: "autobuffy_V1_client",
      userName: ENV['PARTS_USER'],
      userPass: ENV['PARTS_PASSWORD'],
    }
  end

  def push_order ref_numbers, order
    return unless check_order_status generate_po_number(order)

    @request_body[:action] = "enterOrder"
    @request_body[:orderHeader] = {
      cust_name: Rails.env.production? ? order.name : 'test_name',
      order_num: order.external_po_number,
      shipping_details: {
          company: order.shipping_service,
          phone: order.phone,
          phone_ext: "+#{ISO3166::Country[order.country].country_code}",
          residential: "Y"
      },
      ship_add1: order.street,
      ship_add2: order.apt_number,
      ship_city: order.city,
      ship_state: order.state,
      ship_zip: order.zip,
      ship_country: order.country,
      ship_meth: 'FDH',
      status: Rails.env.production? ? 'live' : 'test'
    }
    @request_body[:orderItems] = []
    ref_numbers.split(',').each do |r|
      ref_list = r.split(':')
      @request_body[:orderItems] << {
          part_num: ref_list.first,
          quantity: ref_list.second,
          line_code: ref_list.last
      }      
    end
    response = @conn.get do |req|
      req.params = {
        reqData: @request_body.to_json
      }
    end

    if response.status == 200
      unless JSON.parse(response.body)['responseStatus'] == 'Failed'
        ref_numbers.split(',').each do |item|
          part_number, qty, line_code = item.split ':'
          brand_items = BrandItem.where part_number: part_number
          brand_items.update_all inventory: (brand_items.first.inventory - qty.to_i)
        end
        order.update(pushed: true, items_pushed: true, pushed_to: "parts_authority", status: 'processing')
      end
    else
      Rails.logger.info(response.body)
    end
  end

  def check_order_status po_number
    req_body = @request_body.merge( { action: "getOrderInformation", PoNumber: po_number } )
    conn = Faraday.new(ENV['PARTS_ORDER_URL'])
    response = conn.get do |req|
      req.params = {
        reqData: req_body.to_json
      }
    end

    JSON.parse(response.body).include? 'responseStatus'
  end

  def fetch_tracking order_id
    order = Order.find(order_id)
    @request_body[:PoNumber] = order.external_po_number
    @request_body[:action] = "getOrderShippingDetail"
    response = Faraday.new(ENV['PARTS_ORDER_URL']).get do |req|
      req.params = {
        reqData: @request_body.to_json
      }
    end

    if response.status == 200
      response_body = JSON.parse(response.body)
      unless response_body['responseStatus'] == 'Failed'
        response_body['ShippingInfo'].each do |res|
          order.trackings.create(number: res['tracking_number'], carrier: res['carrier'])   
        end
        PushTrackingJob.perform_later order_id
      end 
    end
  end

  def generate_po_number order
    po_number_ = order.po_number.scan(/\d/).join('')
    order.update(external_po_number: po_number_.size > 11 ? po_number_.first(11) : po_number_)
    order.external_po_number
  end
end
