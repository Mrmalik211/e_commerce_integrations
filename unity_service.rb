require "uri"
require "net/http"

class UnityService
  def initialize
    @url = URI(ENV['UNITY_URL'])
    @form_data = [['USERNAME', ENV['UNITY_USER']],['API_KEY', ENV['UNITY_API_KEY']]]
    @https = Net::HTTP.new(@url.host, @url.port)
    @https.use_ssl = true
  end

  def push_order order
    request = Net::HTTP::Post.new(@url)
    form_data = @form_data + [['ACTION', 'CreateOrderObj'], ['SHIPTONAME', order.name], ['SHIPTOADDRESSSTREET1', Rails.env.production? ? order.street : 'Fake Street'], ['SHIPTOCITY', order.city], ['SHIPTOSTATE', order.state], ['SHIPTOCOUNTRY', order.country], ['UPS_OPTION', '3'], ['ORDERNOTE', Rails.env.production? ? '' : 'VOID ORDER - API Test Order - DO NOT SHIP'], ['SHIPTOPOSTALCODE', order.zip], ['SHIPTOADDRESSSTREET2', order.apt_number]]
    
    request.set_form form_data, 'multipart/form-data'
    response_body = JSON.parse(@https.request(request).read_body)
    if response_body['status_code'] == 1000
      order.update(external_po_number: response_body['order_id'])
    end
    order.external_po_number
  end

  def add_items_in_order order_id, ref_numbers
    return unless order_id.present?

    request = Net::HTTP::Post.new(@url)
    form_data = @form_data + [['ACTION', 'AddOrderItem'], ['ORDER_ID', order_id]]
    total_items_remaining = ref_numbers.split(',').count
    ref_numbers.split(',').each do |r|
      item_form = form_data + [['ITEM_NUM', r.split(':').first], ['ITEM_QTY', r.split(':').last]]
      request.set_form item_form, 'multipart/form-data'
      response_body = JSON.parse(@https.request(request).read_body)
      if response_body['status_code'] == '1001'
        total_items_remaining -= 1
      end
    end
    if total_items_remaining == 0
      order.update(items_pushed: true)
    end
  end

  def issue_order order_id
    request = Net::HTTP::Post.new(url)
    form_data = @form_data + [['ACTION', 'IssueOrder'], ['ORDER_ID', order_id]]
    request.set_form form_data, 'multipart/form-data'
    response_body = JSON.parse(@https.request(request).read_body)
    if response_body['status_code'] == 1004
      order.update(pushed: true, pushed_to: "unity")
    end
  end

  def fetch_tracking order_id
    order = Order.find(order_id)
    request = Net::HTTP::Get.new(url)
    form_data = @form_data + [['ACTION', 'status_order_id'], ['ORDER_ID', order.external_po_number]]
    request.set_form form_data, 'multipart/form-data'
    response_body = JSON.parse(@https.request(request).read_body)
    response_body.each do |r|
      if response_body['status'] == "Issued" && order.trackings.find_by_number(response_body['ups_tracking']).nil?
        order.trackings.create(number: response_body['ups_tracking'], carrier: "UPS")

        PushTrackingJob.perform_later order_id
      end
    end
  end
end
