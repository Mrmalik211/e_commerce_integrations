require "uri"
require "net/http"
require "json"

module Net::HTTPHeader
  def capitalize(name)
    name
  end
  private :capitalize
end

class AmazonService
  def initialize(account_id)
    @account = Account.find account_id
    @region, @service, @aws_request = 'us-east-1', 'execute-api', 'aws4_request'
  end

  def get_token
    set_https "https://api.amazon.com/auth/o2/token"

    request = Net::HTTP::Post.new @uri
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request.body = "grant_type=refresh_token&refresh_token=#{ @account.refresh_token }&client_id=#{ @account.client_id }&client_secret=#{ @account.client_secret }"

    response = @https.request request
    if response.code == '200'
      response_body = JSON.parse response.body
      @account.access_token = response_body['access_token']
      @account.refresh_token = response_body['refresh_token']
      @account.access_token_expiry = response_body['expires_in']
      @account.save
    end
  end

  def get_restricted_token
    set_https "#{ ENV['AMAZON_API_URL'] }/tokens/2021-03-01/restrictedDataToken"
    
    req = Net::HTTP::Post.new @uri
    req.body =  { "targetApplication": ENV['AMAZON_APPLICATION_ID'],
                  "restrictedResources": [
                    {
                      "method": "GET",
                      "path": "/orders/v0/orders"
                    }
                  ]
                }.x
    req = set_request_signature req, Time.now.strftime("%Y%m%d")
    response = @https.request req
  end

  def get_orders
    next_token = ''
    loop do
      set_https "#{ ENV['AMAZON_API_URL'] }/orders/v0/orders?MarketplaceIds=ATVPDKIKX0DER&CreatedAfter=#{ (Time.now).strftime("%Y-%m-%d") }&OrderStatuses=Unshipped%2CPartiallyShipped&NextToken=#{ next_token }"

      req = set_request_signature Net::HTTP::Get.new(@uri), Time.now.strftime("%Y%m%d")
      response = @https.request req
      if response.code == '200'
        response_body = JSON.parse(response.body)['payload']
        response_body['Orders'].each do |order|
          get_order_items(create_order order)
        end

        break unless response_body.keys.include? 'NextToken'
        next_token = ERB::Util.url_encode response_body['NextToken']
      elsif response.code == '403'
        get_token
      end
    end
  end

  def create_order order
    amz_order = @account.orders.find_or_create_by!(po_number: order['AmazonOrderId']) do |new_order|
      new_order.status = order['OrderStatus'] == 'PartiallyShipped' ? :processing : :open
      new_order.city = order['ShippingAddress']['City']
      new_order.country = order['ShippingAddress']['CountryCode']
      # new_order.street = order['shipTo']['contactAddress']['addressLine1']
      # new_order.apt_number = order['shipTo']['contactAddress']['addressLine2']
      new_order.state = order['ShippingAddress']['StateOrRegion']
      new_order.zip = order['ShippingAddress']['PostalCode']
      # new_order.phone = order['shipTo']['primaryPhone']['phoneNumber']
      new_order.email = order['BuyerInfo']['BuyerEmail']
      new_order.shipping_service = order['shippingCarrierCode']
      # new_order.qty_total = order['lineItems'].length
      new_order.order_from = Order.order_froms[:amazon]
      # new_order.name = order['shipTo']['fullName']
      new_order.user = @account.user
    end
  end

  def get_order_items order
    set_https "#{ENV['AMAZON_API_URL']}/orders/v0/orders/#{ order.po_number }/orderItems"

    req = set_request_signature Net::HTTP::Get.new(@uri), Time.now.strftime("%Y%m%d")
    response = @https.request req
    if response.code == '200'
      create_order_items JSON.parse(response.body)['payload']['OrderItems'], order
    elsif response.code == '403'
      get_token
      return get_order_items order
    end
  end
  
  def create_order_items items, order
    order.update(qty_total: items.count)
    items.each do |item|
      amz_item = Item.find_by_external_id item["ASIN"]
      order.order_items.find_or_create_by(item_id: amz_item.id, quantity_ordered: item['QuantityOrdered'], status: :open, external_order_item_id: item['OrderItemId']) if amz_item.present?
    end
    order.update(is_valid: false) unless order.qty_total == order.items.count
  end

  def get_item sku
    set_https "#{ENV['AMAZON_API_URL']}/listings/2021-08-01/items/#{ ENV['AMAZON_SELLER_ID'] }/#{ sku }?marketplaceIds=ATVPDKIKX0DER"

    req = set_request_signature Net::HTTP::Get.new(@uri), Time.now.strftime("%Y%m%d")
    response = @https.request req
    if response.code == '200'
      response_body = JSON.parse(response.body)['summaries'].first
      
    elsif response.code == '403'
      get_token
      return get_item sku
    elsif response.code == '404'
      Rails.logger.info response.body
    end 
  end

  def push_tracking order, tracking_number, carrier
    set_https "#{ ENV['AMAZON_API_URL'] }/orders/v0/orders/#{ order.po_number }/shipmentConfirmation"

    req = Net::HTTP::Post.new @uri
    order.trackings.each do |t|
      req.body = {
        "packageDetail": {
          "packageReferenceId": "",
          "carrierCode": "",
          "carrierName": "",
          "shippingMethod": "",
          "trackingNumber": "",
          "shipDate": "",
          "orderItems": order.order_items.map{ |oi| { orderItemId: oi.external_order_item_id, quantity: oi.quantity_ordered }}
        },
        "marketplaceId": "Test"
      }.to_json
      req = set_request_signature req, Time.now.strftime("%Y%m%d")
    end

  end

  private

  def set_https url
    @uri = URI(url)
    @https = Net::HTTP.new(@uri.host, @uri.port)
    @https.use_ssl = true
  end

  def set_request_signature req, date, 
    date_time = (Rails.env.production? ? Time.now : ( Time.now - 5.hours) ).strftime("%Y%m%dT%H%M%SZ")

    if req.body.present?
      req["Content-Type"] = "application/json" 
      req["X-Amz-Content-Sha256"] = "beaead3198f7da1e70d03ab969765e0821b24fc913697e929e726aeaebf0eba3"
    end

    signature = get_signature "AWS4-HMAC-SHA256\n#{ date_time }\n#{ date }/#{ @region }/#{ @service }/#{ @aws_request }\n#{ OpenSSL::Digest::SHA256.hexdigest(get_canonical_string req, date_time ) }", date
    
    req["x-amz-access-token"] = @account.access_token
    req["X-Amz-Date"] = date_time
    req["Authorization"] = "AWS4-HMAC-SHA256 Credential=#{ ENV['AMAZON_ACCESS_KEY'] }/#{ date }/#{ @region }/#{ @service }/#{ @aws_request }, SignedHeaders=host\;x-amz-access-token#{ "\;x-amz-content-sha256" if req.body.present? }\;x-amz-date, Signature=#{ signature }"
    
    req
  end

  def get_canonical_string req, date_time
    "#{ req.method }\n#{ req.path.split('?').first }\n#{ req.path.split('?').last.split('&').sort.join('&') if req.path.split('?').count > 1 }\nhost:#{ req.uri.hostname }\nx-amz-access-token:#{ @account.access_token }\n#{ "x-amz-content-sha256:#{ req["X-Amz-Content-Sha256"] }\n" if req.body.present? }x-amz-date:#{ date_time }\n\nhost\;x-amz-access-token\;#{ "x-amz-content-sha256\;" if req.body.present? }x-amz-date\n#{ OpenSSL::Digest::SHA256.hexdigest req.body.to_s }"  
  end

  def get_signature string_to_sign, date
    kDate = hmac("AWS4" + ENV['AMAZON_SECRET_KEY'], date)
    kRegion = hmac kDate, @region
    kService = hmac kRegion, @service
    kSigning = hmac kService, @aws_request

    hexhmac kSigning, string_to_sign
  end

  def hmac(key, value)
    OpenSSL::HMAC.digest OpenSSL::Digest.new('sha256'), key, value
  end

  def hexhmac(key, value)
    OpenSSL::HMAC.hexdigest OpenSSL::Digest.new('sha256'), key, value
  end
end
