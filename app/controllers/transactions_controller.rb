class TransactionsController < ApplicationController

  before_action only: [:show] do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_inbox")
  end

  before_action only: [:new] do |controller|
    fetch_data(params[:listing_id]).on_success do |listing_id, listing_model, _, process|
      record_event(
        flash,
        "BuyButtonClicked",
        { listing_id: listing_id,
          listing_uuid: listing_model.uuid_object.to_s,
          payment_process: process.process,
          user_logged_in: @current_user.present?
        })
    end
  end

  before_action do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_do_a_transaction")
  end

  TransactionForm = EntityUtils.define_builder(
    [:listing_id, :fixnum, :to_integer, :mandatory],
    [:message, :string],
    [:quantity, :fixnum, :to_integer, default: 1],
    [:start_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ],
    [:end_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ]
  )

  def new
    Result.all(
      ->() {
        fetch_data(params[:listing_id])
      },
      ->((listing_id, listing_model)) {
        ensure_min_days_booking(listing_model)
      },
      ->((listing_id,listing_model),_) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community, start_on: params[:start_on], end_on: params[:end_on])
      }
    ).on_success { |((listing_id, listing_model, author_model, process, gateway),_)|
      transaction_params = HashUtils.symbolize_keys(
        {listing_id: listing_model.id}
        .merge(params.slice(:start_on, :end_on, :quantity, :delivery, :start_time, :end_time, :per_hour,:origin_loc, :unit_type, :app_session_token).permit!)
      )
      case [process.process, gateway]
      when matches([:none])
        render_free(listing_model: listing_model, author_model: author_model, community: @current_community, params: transaction_params)
      when matches([:preauthorize, :paypal]), matches([:preauthorize, :stripe]), matches([:preauthorize, :razorpay]), matches([:preauthorize, [:paypal, :stripe, :razorpay]]), matches([:preauthorize, [:stripe, :razorpay]]), matches([:preauthorize, [:paypal, :stripe]]), matches([:preauthorize, [:paypal, :razorpay]])
        redirect_to initiate_order_path(transaction_params)
      else
        opts = "listing_id: #{listing_id}, payment_gateway: #{gateway}, payment_process: #{process}, booking: #{booking}"
        raise ArgumentError.new("Cannot find new transaction path to #{opts}")
      end
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      if params[:app_session_token].present?
        if TbActiveAppSession.find_by_session_token(params[:app_session_token]).try(:person) == @current_user
          redirect_to api_v1_app_payment_callback_path(:payment_error_callback => true, :error => flash[:error])
        else
          redirect_to(session[:return_to_content] || root)
        end
      else
        redirect_to(session[:return_to_content] || root)
      end
    }
    
  end

  def create

    Result.all(
      ->() {
        TransactionForm.validate(params)
      },
      ->(form) {
        fetch_data(form[:listing_id])
      },
      ->(form, (_, _, _, process)) {
        validate_form(form, process)
      },
      ->(_, (listing_id, listing_model), _) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community, start_on: params[:start_on], end_on: params[:end_on])
      },
      ->(form, (listing_id, listing_model, author_model, process, gateway), _, _) {
        booking_fields = Maybe(form).slice(:start_on, :end_on).select { |booking| booking.values.all? }.or_else({})

        is_booking = date_selector?(listing_model)
        quantity = calculate_quantity(tx_params: {
                                        quantity: form[:quantity],
                                        start_on: booking_fields.dig(:start_on),
                                        end_on: booking_fields.dig(:end_on)
                                      },
                                      is_booking: is_booking,
                                      unit: listing_model.unit_type&.to_sym)

        if (params["textTitle"])
          titleObject = [
            {
              :title => params[:textTitle],
              :value => params[:additional_text_field]
            }
          ].to_json
        end
        if (params["dropdownTitle"])
          titleObject = [
            {
              :title => params[:dropdownTitle],
              :value => params[:additionInfoDropdown].to_f
            }
          ].to_json
        end
        if (params["dropdownTitle"] && params["textTitle"])
          titleObject = [
            {
              :title => params[:textTitle],
              :value => params[:additional_text_field]
            },
            {
              :title => params[:dropdownTitle],
              :value => params[:additionInfoDropdown].to_f
            }
          ].to_json
        end
        if (!params["dropdownTitle"] && !params["textTitle"])
          titleObject = ''
        end
        price = calculate_additional_checkout_price(params["checkout-fields"])
        transaction_service.create(
          {
            transaction: {
              community_id: @current_community.id,
              community_uuid: @current_community.uuid_object,
              listing_id: listing_id,
              listing_uuid: listing_model.uuid_object,
              listing_title: listing_model.title,
              starter_id: @current_user.id,
              starter_uuid: @current_user.uuid_object,
              listing_author_id: author_model.id,
              listing_author_uuid: author_model.uuid_object,
              unit_type: listing_model.unit_type,
              unit_price: listing_model.price,
              unit_tr_key: listing_model.unit_tr_key,
              availability: listing_model.availability,
              listing_quantity: quantity,
              content: form[:message],
              starting_page: ::Conversation::PAYMENT,
              booking_fields: booking_fields,
              payment_gateway: process.process == :none ? :none : gateway, # TODO This is a bit awkward
              payment_process: process.process,
              additional_info: titleObject,
              additional_price: params[:additionInfoDropdown].to_f,
              checkout_field_price_cents: price || 0
            }
          })
      }
    ).on_success { |(_, (_, _, _, process), _, _, tx)|
      after_create_actions!(process: process, transaction: tx[:transaction], community_id: @current_community.id)
      flash[:notice] = after_create_flash(process: process) # add more params here when needed
      redirect_to after_create_redirect(process: process, starter_id: @current_user.id, transaction: tx[:transaction]) # add more params here when needed
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }
  end
  def show
    @transaction = @current_community.transactions.find(params[:id])
    m_admin = @current_user.has_admin_rights?(@current_community)
    m_participant = @current_user.id == @transaction.starter_id || @current_user.id == @transaction.listing_author_id
    unless m_admin || m_participant
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
      return redirect_to search_path
    end

    role =
      if m_participant
        :participant
      elsif m_admin
        :admin
      end

    @conversation = @transaction.conversation
    @listing = @transaction.listing

    messages_and_actions = TransactionViewUtils.merge_messages_and_transitions(
      TransactionViewUtils.conversation_messages(@conversation.messages, @current_community.name_display_type),
      TransactionViewUtils.transition_messages(@transaction, @conversation, @current_community.name_display_type))
    @transaction.mark_as_seen_by_current(@current_user.id)
    is_author = m_admin || @transaction.listing_author_id == @current_user.id
    email = Email.find_by(person_id: @current_user[:id])
    render action:get_partial_path+"show", locals: {
      messages: messages_and_actions.reverse,
      conversation_other_party: @conversation.other_party(@current_user),
      is_author: is_author,
      role: role,
      message_form: Message.new({sender_id: @current_user.id, conversation_id: @conversation.id}),
      message_form_action: person_message_messages_path(@current_user, :message_id => @conversation.id),
      price_break_down_locals: price_break_down_locals(@transaction, @conversation)
    }
  end

  def created
    proc_status = transaction_service.finalize_create(
      community_id: @current_community.id,
      transaction_id: params[:transaction_id],
      force_sync: false)

    unless proc_status[:success]
      flash[:error] = t("error_messages.booking.booking_failed_payment_voided")
      return redirect_to search_path
    end

    tx_fields = proc_status.dig(:data, :transaction_service_fields) || {}
    process_token = tx_fields[:process_token]
    process_completed = tx_fields[:completed]

    if process_token.present?
      redirect_url = transaction_finalize_processed_path(process_token)

      if process_completed
        redirect_to redirect_url
      else
        # Operation was performed asynchronously

        # We're using here the same PayPal spinner, although we could
        # create a new one for TransactionService.
        render "paypal_service/success", layout: false, locals: {
                 op_status_url: transaction_op_status_path(process_token),
                 redirect_url: redirect_url
               }
      end
    else
      handle_finalize_proc_result(proc_status)
    end
  end

  def finalize_processed
    process_token = params[:process_token]

    proc_status = transaction_process_tokens.get_status(UUIDTools::UUID.parse(process_token))
    unless (proc_status[:success] && proc_status[:data][:completed])
      return redirect_to error_not_found_path
    end

    handle_finalize_proc_result(proc_status[:data][:result])
  end

  def transaction_op_status
    process_token = params[:process_token]

    resp = Maybe(process_token)
             .map { |ptok|
               uuid = UUIDTools::UUID.parse(process_token)
               transaction_process_tokens.get_status(uuid)
             }
             .select(&:success)
             .data
             .or_else(nil)

    if resp
      render json: process_resp_to_json(resp)
    else
      head :not_found
    end
  end

  def person_with_url(person)
    {
      person: person_entity,
      url: person_path(username: person.username),
      display_name: PersonViewUtils.person_display_name(person, @current_community.name_display_type)
    }
  end

  private

  def calculate_additional_checkout_price(data)
    additional_price = 0
    checkout_fields =  data
    if requiresJSONParse(checkout_fields)
      checkout_fields = JSON.parse(checkout_fields)
    end  
    begin
      additional_price = (checkout_fields.select { |cf| cf["type"] == "DropdownField"}.map{ |sf| sf["value"].map{ |sv| sv["value"].to_i }.sum }.sum ) * 100 
    rescue => exception 
    else 
    end 
    additional_price
  end

  def handle_finalize_proc_result(response)
    response_data = response[:data] || {}

    if response[:success]
      tx = response_data[:transaction]

      record_event(
        flash,
        "TransactionCreated",
        { listing_id: tx.listing_id,
          listing_uuid: UUIDUtils.parse_raw(tx.listing_uuid).to_s,
          transaction_id: tx.id,
          payment_process: tx.payment_process })

      redirect_to person_transaction_path(person_id: @current_user.id, id: tx.id)
    else
      listing_id = response_data[:listing_id]

      flash[:error] =
        case response_data[:reason]
        when :connection_issue
          t("error_messages.booking.booking_failed_payment_voided")
        when :double_booking
          t("error_messages.booking.double_booking_payment_voided")
        else
          t("error_messages.booking.booking_failed_payment_voided")
        end

      redirect_to person_listing_path(person_id: @current_user.id, id: listing_id)
    end
  end

  def ensure_can_start_transactions(listing_model:, current_user:, current_community:, start_on:, end_on:)
    error =
      if listing_model.closed?
        "layouts.notifications.you_cannot_reply_to_a_closed_offer"
      elsif listing_model.author == current_user
       "layouts.notifications.you_cannot_send_message_to_yourself"
      elsif !Policy::ListingPolicy.new(listing_model, current_community, current_user).visible?
        "layouts.notifications.you_are_not_authorized_to_view_this_content"
      elsif listing_model.has_booking_and_blocked_dates(start_on, end_on)
         "listing_conversations.preauthorize.dates_not_available"
      end

    if error
      Result::Error.new(error, {error_tr_key: error})
    else
      Result::Success.new
    end
  end

  def after_create_flash(process:)
    case process.process
    when :none
      case
        when @current_community.checkout_flow == 1
          t("layouts.notifications.order_placed")
        else
          t("layouts.notifications.message_sent")
        end
      
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def requiresJSONParse(unit) 
    begin 
        JSON.parse(unit) 
       return true 
    rescue => e 
       return false 
    end 
  end

  def add_checkout_fieds_to_transaction(tr_id)
    @checkout_fields =  params["checkout-fields"]
    if @checkout_fields
      if requiresJSONParse(@checkout_fields)
        @checkout_fields = JSON.parse(@checkout_fields)
      end  
      @checkout_fields.each do |cf|
        case cf["type"]
        when "DropdownField"
          @selected_options = cf["value"]
          if requiresJSONParse(@selected_options)
            @selected_options = JSON.parse(@selected_options)
          end  
          tcf = TransactionCheckoutField.create(:community_id => @current_community.id,:transaction_id => tr_id, :title => cf["title"],:field_type => cf["type"])
          @selected_options.each do |sv|
            tcf.transaction_checkout_field_selections.create(:community_id => @current_community.id,:transaction_id => tr_id, :label => sv["label"], :value => sv["value"], :description => sv["description"] )
          end
        else   
          TransactionCheckoutField.create(:community_id => @current_community.id,:transaction_id => tr_id, :title => cf["title"],:field_type => cf["type"], :value => cf["value"] )
        end 
      end
    else  
    end

  end

  def after_create_redirect(process:, starter_id:, transaction:)
    @deliveryData = {
      :latitude => Maybe(params["delivery_lat"]).or_else(""),
      :longitude => Maybe(params["delivery_long"]).or_else(""),
      :google_address => params["delivery-address"] ? (params["apartment-no"] + ", " + params["landmark"] + ", "+ params["delivery-address"] +", "+ (Maybe(params["postal_code"]).or_else(""))) : "",
      :delivery_charge => Maybe(params["estimated_fare"]).or_else("")
    }
    add_checkout_fieds_to_transaction(transaction[:id])
    case process.process
    when :none  
    person_transaction_path(person_id: starter_id, id: transaction[:id])
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_actions!(process:, transaction:, community_id:)
    case process.process
    when :none
      # TODO Do I really have to do the state transition here?
      # Shouldn't it be handled by the TransactionService
      TransactionService::StateMachine.transition_to(transaction[:id], "free")

      transaction = Transaction.find(transaction[:id])

      Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, community_id))
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def ensure_min_days_booking(listing_model)
    Result.all(
      ->(){
        error = false 
        if [:day, :night].include?(listing_model.quantity_selector&.to_sym)
            if DateUtils.duration(Date.parse(params["start_on"]),Date.parse(params["end_on"])) < listing_model[:min_booking_days] 
                error = true
            end     
        end
        if error 
          Result::Error.new("mininum booking #{listing_model.quantity_selector}s must be #{listing_model[:min_booking_days] }")
        else  
          Result::Success.new()
        end
      }
    )
  end   


  # Fetch all related data based on the listing_id
  #
  # Returns: Result::Success([listing_id, listing_model, author, process, gateway])
  #

  def fetch_data(listing_id)
    Result.all(
      ->() {
        if listing_id.nil?
          Result::Error.new("No listing ID provided")
        else
          Result::Success.new(listing_id)
        end
      },
      ->(l_id) {
        Maybe(@current_community.listings.where(id: l_id).first)
          .map     { |listing_model| Result::Success.new(listing_model) }
          .or_else { Result::Error.new("Cannot find listing with id #{l_id}") }
      },
      ->(_, listing_model) {
        Result::Success.new(listing_model.author)
      },
      ->(_, listing_model, *rest) {
        TransactionService::API::Api.processes.get(community_id: @current_community.id, process_id: listing_model.transaction_process_id)
      },
      ->(*) {
        Result::Success.new(@current_community.active_payment_types)
      }
    )
  end

  def validate_form(form_params, process)
    if process.process == :none && form_params[:message].blank?
      Result::Error.new("Message cannot be empty")
    else
      Result::Success.new
    end
  end

  def price_break_down_locals(tx, conversation)
    if tx.payment_process == :none && tx.unit_price.cents == 0 || conversation.starting_page == Conversation::LISTING
      nil
    else
      localized_unit_type = tx.unit_type.present? ? ListingViewUtils.translate_unit(tx.unit_type, tx.unit_tr_key) : nil
      localized_selector_label = tx.unit_type.present? ? ListingViewUtils.translate_quantity(tx.unit_type, tx.unit_selector_tr_key) : nil
      booking = !!tx.booking
      booking_per_hour = tx.booking && tx.booking.per_hour
      quantity = tx.listing_quantity
      show_subtotal = !!tx.booking || quantity.present? && quantity > 1 || tx.shipping_price.present?
      total_label = (tx.payment_process != :preauthorize) ? t("transactions.price") : t("transactions.total")
      payment = TransactionService::Transaction.payment_details(tx)
      

      TransactionViewUtils.price_break_down_locals({
        listing_price: tx.unit_price,
        localized_unit_type: localized_unit_type,
        localized_selector_label: localized_selector_label,
        booking: booking,
        start_on: booking ? tx.booking.start_on : nil,
        end_on: booking ? tx.booking.end_on : nil,
        duration: booking ? tx.listing_quantity : nil,
        quantity: quantity,
        subtotal: show_subtotal ? tx.item_total : nil,
        total: Maybe(tx.payment_total).or_else(payment[:total_price]),
        seller_gets: Maybe(tx.payment_total).or_else(payment[:total_price]) - tx.commission,
        fee: tx.commission,
        shipping_price: tx.shipping_price,
        total_label: total_label,
        unit_type: tx.unit_type,
        per_hour: booking_per_hour,
        start_time: booking_per_hour ? tx.booking.start_time : nil,
        end_time: booking_per_hour ? tx.booking.end_time : nil,
      })
    end
  end

  def render_free(listing_model:, author_model:, community:, params:)
    @listing = listing_model
    listing = {
      id: listing_model.id,
      title: listing_model.title,
      action_button_label: t(listing_model.action_button_tr_key),
    }
    author = {
      display_name: PersonViewUtils.person_display_name(author_model, community),
      username: author_model.username
    }

    unit_type = listing_model.unit_type.present? ? ListingViewUtils.translate_unit(listing_model.unit_type, listing_model.unit_tr_key) : nil
    localized_selector_label = listing_model.unit_type.present? ? ListingViewUtils.translate_quantity(listing_model.unit_type, listing_model.unit_selector_tr_key) : nil
    booking_start = Maybe(params)[:start_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking_end = Maybe(params)[:end_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking = date_selector?(listing_model)

    quantity = calculate_quantity(tx_params: {
                                    start_on: booking_start,
                                    end_on: booking_end,
                                    quantity: TransactionViewUtils.parse_quantity(params[:quantity])
                                  },
                                  is_booking: booking,
                                  unit: listing_model.unit_type)

    total_label = t("transactions.price")

    m_price_break_down = Maybe(listing_model).select { |l_model| l_model.price.present? }.map { |l_model|
      TransactionViewUtils.price_break_down_locals(
        {
          listing_price: l_model.price,
          localized_unit_type: unit_type,
          localized_selector_label: localized_selector_label,
          booking: booking,
          start_on: booking_start,
          end_on: booking_end,
          duration: quantity,
          quantity: quantity,
          subtotal: quantity != 1 ? l_model.price * quantity : nil,
          total: l_model.price * quantity,
          shipping_price: nil,
          total_label: total_label,
          unit_type: l_model.unit_type
        })
    }
    @additional_information = CheckoutField.where("community_id = #{@current_community.id}")
    render action:get_partial_path+"new", locals: {
             image_s3_options: image_s3_options,
             listing: listing,
             author: author,
             action_button_label: t(listing_model.action_button_tr_key),
             m_price_break_down: m_price_break_down,
             additional_information: @additional_information,
             booking_start: booking_start,
             booking_end: booking_end,
             quantity: quantity,
             form_action: person_transactions_path(person_id: @current_user, listing_id: listing_model.id)
           }
  end

  def date_selector?(listing)
    [:day, :night].include?(listing.quantity_selector&.to_sym)
  end

  def calculate_quantity(tx_params:, is_booking:, unit:)
    if is_booking
      puts tx_params[:start_on].class
      DateUtils.duration(tx_params[:start_on], tx_params[:end_on])
    else
      tx_params[:quantity] || 1
    end
  end

  def process_resp_to_json(resp)
    if resp[:completed]
      {
        completed: true,
        result: {
          success: resp[:result][:success],
          data: {
            redirect_url: resp.dig(:result, :data, :redirect_url)
          }
        }
      }
    else
      { completed: false }
    end
  end

  def transaction_service
    TransactionService::Transaction
  end

  def transaction_process_tokens
    TransactionService::API::Api.process_tokens
  end

  def has_images?(listing)
    !listing.listing_images.empty?
  end

  def get_partial_path
    case @current_theme_identifier
    when "flex-theme"
      partial_path = "flex-theme/"
    else
      partial_path = ""
    end
  end

  def image_s3_options 
    s3uploader = S3Uploader.new 
    return s3uploader.checkout_page_fields.to_json 
  end

end
