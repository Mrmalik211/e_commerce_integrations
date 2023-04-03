class WestarService
  def initialize(account_id)
    @account = if account_id
      Account.find account_id
    end
    @conn = Faraday.new(url: Rails.env == 'development' ? ENV['WESTAR_LOCAL_URL'] : ENV['WESTAR_PROD_URL'])
    @conn.headers = { 'Content-Type': 'application/json',
      Authorization: "Bearer #{@account.access_token}"
    }
  end

  def refresh_token
    @conn.params = { grant_type: 'refresh_token',
                     refresh_token: @account.refresh_token,
                     client_id: @account.client_id,
                     client_secret: @account.client_secret
                   }
    response = @conn.post('/oauth/token')
    access = JSON.parse(response.body)
    @account.access_token = access['access_token']
    @account.access_token_expiry = access['expires_in']
    @account.refresh_token = access['refresh_token']
    @account.save
    @conn.headers = { 'Content-Type': 'application/json',
      Authorization: "Bearer #{@account.access_token}"
    }
  end 

  def get_westar_cost ref_numbers
    status_res = @conn.post('/api/v1/items/inventory_status') do |req|
      req.body = { order: ref_numbers }.to_json
    end
    if status_res.status == 200
      all_part_numbers = ref_numbers.split(',').map{ |i| i.split(':').first}
      cost_res = @conn.post('/api/v1/items/inventory_cost') do |req|
        req.body = { part_numbers: all_part_numbers }.to_json
      end
      if cost_res.status == 200
        response_body = JSON.parse cost_res.body
        return all_part_numbers.map{ |p| response_body['data'][p].first['cost'] }.sum
      end
    elsif status_res.status == 401
      refresh_token
      get_westar_cost ref_numbers
    end
  end

  def push_to_westar ref_numbers, order
    ref_numbers = ref_numbers.split(',').map{|r| r.split(':')[0..1].join(':') }.join(',')
    request_body = {order_number: order.po_number,
                    ship_to_phone: order.phone,
                    buyer_name: order.name,
                    buyer_city: order.city,
                    buyer_state: order.state,
                    buyer_zip: order.zip,
                    buyer_email: order.email,
                    shipping_service: order.shipping_service,
                    buyer_address1: order.street,
                    buyer_street: order.street,
                    buyer_address2: order.apt_number,
                    reference_numbers: ref_numbers,
                    country: order.country
                   }
    response = @conn.post('/api/v1/orders') do |req|
      req.body = request_body.to_json
    end
    case response.status
    when 401
      refresh_token
      push_to_westar ref_numbers, order
    when 200
      ref_numbers.split(',').each do |item|
        part_number, qty = item.split ':'
        brand_items = BrandItem.where part_number: part_number
        brand_items.update_all inventory: (brand_items.first.inventory - qty.to_i)
      end
      order.update(pushed: true, items_pushed: true, pushed_to: "westar", status: 'processing')
      # FetchTrackingJob.set(wait: 2.hours).perform_later @account.id, order.id
      response.body
    end
  end

  def fetch_tracking order_id
    response = @conn.post('/api/v1/orders/tracking') do |req|
      req.body = { "po_numbers": [ Order.find(order_id).po_number ] }.to_json
    end
    case response.status
    when 401
      refresh_token
      return fetch_tracking order_id
    when 200
      response_data = JSON.parse(response.body)['data'].first.second
      response_data.each do |data|
        Order.find(order_id).trackings.create(number: data['tracking_number'], carrier: data['provider'])
      end
      PushTrackingJob.perform_later order_id
      return true
    when 204
      return false
    end
  end
end