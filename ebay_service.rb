require 'faraday'
require 'json'
require 'uri'
require 'active_support/core_ext'

class EbayService
  def initialize(account_id = nil)
    @conn = Faraday.new(url: ENV['EBAY_API_URL'])
    @account = if account_id
                 Account.find account_id
               end
  end

  def get_traditional_call_header call, account_id
    {
      'X-EBAY-API-SITEID': '0',
      'X-EBAY-API-COMPATIBILITY-LEVEL': '967',
      'X-EBAY-API-IAF-TOKEN': Account.find(account_id).access_token,
      'X-EBAY-API-CALL-NAME': call
    }
  end
  def get_token(mint_new_token = false)
    @conn.headers = { 'Content-Type': 'application/x-www-form-urlencoded',
                      Authorization: "Basic #{Base64.strict_encode64(@account.client_id + ":" + @account.client_secret)}"
    }
    body = {}
    body['grant_type'] = if mint_new_token
                           'refresh_token'
                         else
                           'authorization_code'
                         end
    if mint_new_token
      body['refresh_token'] = @account.refresh_token
      body['scope'] = 'https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.fulfillment'
    else
      body['redirect_uri'] = 'AutoBuffy-AutoBuff-Vendor-qlzes'
      body['code'] = @account.consent_code
    end
    
    response = @conn.post('/identity/v1/oauth2/token') do |req|
      req.body = URI.encode_www_form(body)
    end
    json_body = JSON.parse(response.body)
    @account.access_token = json_body['access_token'] if json_body['access_token'].present?
    @account.access_token_expiry = json_body['expires_in'] if json_body['expires_in'].present?
    @account.refresh_token = json_body['refresh_token'] if json_body['refresh_token'].present?
    @account.refresh_token_expiry = json_body['refresh_token_expires_in'] if json_body['refresh_token_expires_in'].present?
    @account.save if @account.access_token.present? and @account.refresh_token.present?
  end

  def get_orders account_id, user_id
    orders = []
    @account = Account.find(account_id)
    @conn.headers = { 'Content-Type': 'application/json',
                      Authorization: "Bearer #{@account.access_token}"
                    }
    offset = 0
    loop do
      @conn.params = { filter: 'orderfulfillmentstatus:{NOT_STARTED | IN_PROGRESS}',
                      limit: 100,
                      offset: offset
                    }
      response = @conn.get('/sell/fulfillment/v1/order')
      response_body = JSON.parse(response.body)
      ebay_orders = response_body['orders']
      if response.body['errors'].present?
        get_token true
        return get_orders account_id, user_id
      else
        if ebay_orders.present?
          ebay_orders.each do |order|
            orders.push create_order(order)
          end
        end
      end
      break if response_body['next'].nil?
      offset += 100
    end
    
    # CheckAndPushOrdersJob.perform_later user_id
    orders
  end

  def create_order order
    order_status = if order['orderFulfillmentStatus'] == 'NOT_STARTED'
                    :open
                   elsif order['orderFulfillmentStatus'] == 'IN_PROGRESS'
                    :processing
                   elsif order['orderFulfillmentStatus'] == 'FULFILLED'
                    :completed
                   end
    ebay_order = @account.orders.find_or_create_by(po_number: order['orderId']) do |new_order|
      new_order.status = order_status
      shipping_step = order['fulfillmentStartInstructions'].first['shippingStep']
      new_order.city = shipping_step['shipTo']['contactAddress']['city']
      new_order.country = shipping_step['shipTo']['contactAddress']['countryCode']
      new_order.street = shipping_step['shipTo']['contactAddress']['addressLine1']
      new_order.apt_number = shipping_step['shipTo']['contactAddress']['addressLine2']
      new_order.state = shipping_step['shipTo']['contactAddress']['stateOrProvince']
      new_order.zip = shipping_step['shipTo']['contactAddress']['postalCode']
      new_order.phone = shipping_step['shipTo']['primaryPhone']['phoneNumber']
      new_order.email = shipping_step['shipTo']['email']
      new_order.shipping_service = shipping_step['shippingCarrierCode']
      new_order.qty_total = order['lineItems'].length
      new_order.order_from = Order.order_froms[:ebay]
      new_order.name = shipping_step['shipTo']['fullName']
      new_order.user = @account.user
    end
    create_order_items order["lineItems"], ebay_order
  end

  def create_order_items items, order
    items.each do |item|
      ebay_item = Item.find_by_external_id item["legacyItemId"]
      if ebay_item.present?
        order.order_items.find_or_create_by(item_id: ebay_item.id, quantity_ordered: item['quantity'], status: :open)
      else
        order.update is_valid: false
      end
    end
  end

  def get_items user_id, account_ids
    start_time_to = Date.today
    loop do
      page = 1
      has_items = true
      start_time_from = start_time_to - 120
      account_ids.each do |id|
        @conn.headers = get_traditional_call_header 'GetSellerList', id
        loop do
          request_body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><GetSellerListRequest xmlns=\"urn:ebay:apis:eBLBaseComponents\"><ErrorLanguage>en_US</ErrorLanguage><WarningLevel>High</WarningLevel><GranularityLevel>Coarse</GranularityLevel><StartTimeFrom>#{start_time_from.to_s}</StartTimeFrom><StartTimeTo>#{start_time_to.to_s}</StartTimeTo><IncludeWatchCount>true</IncludeWatchCount><Pagination><EntriesPerPage>200</EntriesPerPage><PageNumber>#{page}</PageNumber></Pagination><OutputSelector>ItemID</OutputSelector><OutputSelector>HasMoreItems</OutputSelector><OutputSelector>ReturnedItemCountActual</OutputSelector></GetSellerListRequest>"
          response = @conn.post('/ws/api.dll') do |req|
            req.body = request_body
          end
          response_body = Hash.from_xml(response.body.to_s)['GetSellerListResponse']
          if response_body['Errors'].present?
            @account = Account.find(id)
            get_token true
            break true
          elsif response_body['ReturnedItemCountActual'].to_i > 0
            BulkImportItemsJob.set(wait: 1.minutes).perform_later(user_id, response_body['ItemArray']['Item'].map { |item| item['ItemID']}, id)
          else
            has_items = false
          end
          break if response_body['HasMoreItems'] == 'false'
          page += 1
        end
      end
      break unless has_items
      start_time_to = start_time_from
    end
  end

  def get_item_details external_id
    conn = Faraday.new(url: ENV['EBAY_API_URL'])
    conn.headers = get_traditional_call_header 'GetItem', @account.id
    request_body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>
    <GetItemRequest xmlns=\"urn:ebay:apis:eBLBaseComponents\"><ErrorLanguage>en_US</ErrorLanguage><WarningLevel>High</WarningLevel><IncludeItemSpecifics>true</IncludeItemSpecifics><ItemID>#{external_id}</ItemID></GetItemRequest>"
    response = conn.post('/ws/api.dll') do |req|
      req.body = request_body
    end
    item_response = Hash.from_xml(response.body.to_s)['GetItemResponse']
    if item_response['Ack'] == 'Failure'
      get_token true
      return get_item_details external_id
    end
    item_response['Item']
  end

  def push_changes cost, inventory, item_id, account_id
    total_fee = nil
    @conn.headers = get_traditional_call_header 'ReviseFixedPriceItem', account_id
    request_body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><ReviseFixedPriceItemRequest xmlns=\"urn:ebay:apis:eBLBaseComponents\"><ErrorLanguage>en_US</ErrorLanguage><WarningLevel>High</WarningLevel><Item><ItemID>#{item_id}</ItemID><StartPrice>#{cost}</StartPrice><Quantity>#{inventory}</Quantity></Item></ReviseFixedPriceItemRequest>"
    response = @conn.post('/ws/api.dll') do |req|
      req.body = request_body
    end
    response_body = Hash.from_xml(response.body.to_s)["ReviseFixedPriceItemResponse"]
    
    if response_body["Ack"] == "Success"
      total_fee = response_body["Fees"]["Fee"].map { |fee| fee["Fee"].to_i }.sum
    else
      @account = Account.find(account_id)
      get_token true
      return push_changes cost, inventory, item_id, account_id
    end
    
    total_fee
  end

  def fetch_competitor competitor_id, item_id
    @conn.headers = { 'Content-Type': 'application/json',
                      Authorization: "Bearer #{@account.access_token}"
                    }
    response = @conn.get("/buy/browse/v1/item/get_item_by_legacy_id?legacy_item_id=#{competitor_id}")
    if response.body['errors'].present?
      unless response.status == 404
        get_token true
        return fetch_competitor competitor_id, item_id
      end
      return nil
    end
    item = JSON.parse response.body
    Item.find(item_id).competitors << Competitor.find_or_create_by(external_id: competitor_id, cost: item['price']['value'])
  end

  def push_tracking po_number, tracking_number, carrier
    # hard-coded values for testing #
    # po_number = "23-08885-73169"
    # tracking_number = "1ZA684E70316627398"
    # carrier = "FedEx Ground or FedEx Home Delivery"
    
    @conn.headers = get_traditional_call_header 'CompleteSale', @account.id
    request_body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteSaleRequest xmlns=\"urn:ebay:apis:eBLBaseComponents\"><ErrorLanguage>en_US</ErrorLanguage><WarningLevel>High</WarningLevel><OrderID>#{po_number}</OrderID><Shipment><ShipmentTrackingDetails><ShipmentTrackingNumber>#{tracking_number}</ShipmentTrackingNumber><ShippingCarrierUsed>#{carrier}</ShippingCarrierUsed></ShipmentTrackingDetails></Shipment></CompleteSaleRequest>"
    response = @conn.post('/ws/api.dll') do |req|
      req.body = request_body
    end
    response_body = Hash.from_xml(response.body.to_s)['CompleteSaleResponse']
    case response_body['Ack']
    when 'Failure'
      get_token true
      return push_tracking(po_number, tracking_number, carrier)
    when 'Success'
      return true
    end
  end
end
