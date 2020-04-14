ruleset shop {
  meta {
    use module shop_keys
    use module customer_communication alias twilio
      with account_sid = keys:twilio{"account_sid"}
      auth_token = keys:twilio{"auth_token"}
    
    use module google_maps_keys
    use module distance
      with api_key= keys:maps{"api_key"}
      
    use module shop_profile alias profile
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscription
    
    shares __testing, get_known_drivers, get_known_driver_names, get_schedule, get_deliveries, get_bids
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_known_drivers" },
        { "name": "get_known_driver_names"},
        { "name": "get_schedule"},
        { "name": "get_deliveries"},
        { "name": "get_bids", "args": ["delivery_id"]}
      ] , "events":
      [ //{ "domain": "d1", "type": "t1" }
        { "domain": "shop", "type": "new_order", "attrs": [ "destination", "pickup time", "delivery deadline", "customer's number" ] },
        { "domain": "shop", "type": "update_max_distance", "attrs": [ "max_distance" ] },
        { "domain": "shop", "type": "manually_accept_bid", "attrs": ["delivery_id", "driver_id"]}
      ]
    }
    
    get_known_drivers = function() {
      ent:known_drivers
    }
    get_known_driver_names = function() {
      ent:known_driver_names
    }
    
    get_schedule = function() {
      schedule:list()
    }
    
    get_bids = function(delivery_id) {
      ent:delivery_bids{delivery_id}
    }
    
    get_deliveries = function() {
      ent:delivery_requests
    }
    
    get_longest_driver = function() {
      result = ent:known_drivers.values().sort(function(a,b){
        atime = a{"last_delivery"}
        btime = b{"last_delivery"}
        //time:compare(atime,btime) <-- apparently this has not been implemented...
        atime <=> btime
      })
      furthest = result.head()
      driver = ent:known_drivers.filter(function(v,k){
        furthest{"name"} == v{"name"}
      }).keys().head()
      driver
    }
    
    new_message_ID = function(){
      oldseq = ent:message_seq
      picoid = meta:picoId
      return picoid + ":" + oldseq
    }
    new_delivery_ID = function(){
      oldseq = ent:delivery_seq
      picoid = meta:picoId
      return picoid + ":" + oldseq
    }
    
    // store profile
    //     location
    //     min driver rating
    // time for pick up (typically now)
    // required delivery time for urgent deliveries --> defaults to midnight same day
    
    create_new_delivery_request_rumor_message = function(profile, destination, pickup_time, deadline, customer_number) {
      {
        "Message_ID": new_message_ID(),
        "Type": "Delivery_Request",
        "Delivery_ID": new_delivery_ID(),
        "Shop_Profile": profile,
        "Delivery_Destination": destination,
        "Pickup_Time": pickup_time,
        "Delivery_Deadline": deadline,
        "Customer_Number": customer_number
      }
    }
    
    create_bid_accepted_message = function(delivery_id, driver_id) {
      {
        "Message_ID": new_message_ID(),
        "Type": "Bid_Accepted",
        "Delivery_ID": delivery_id,
        "Assigned_Driver": driver_id
      }
    }
    
    does_driver_qualify = function(delivery_id, driver_profile) {
      delivery_req = ent:delivery_requests.get(delivery_id)
      
      shop_profile = delivery_req{"Shop_Profile"}
      shop_location = shop_profile{"location"}
      min_driver_rating = shop_profile{"min_driver_rating"}
      
      driver_location = driver_profile{"location"}
      driver_rating = driver_profile{"rating"}
      
      
      distance = driver_rating >= min_driver_rating => distance:get_distance(shop_location, driver_location) | ent:max_distance_in_miles + 1

      result = (distance <= ent:max_distance_in_miles) => { "qualified": true, "distance": distance } | 
        ((driver_rating >= min_driver_rating) => { 
          "qualified": false, 
          "distance": distance:get_distance(shop_location, driver_location) 
        } | { 
          "qualified": false, 
          "distance": ent:max_distance_in_miles
        })
        
      result.klog("Result:- ")
    }
    
    
    
    max_known_drivers = 5
    min_known_drivers = 2
    need_driver_poll = 30
  }
  
  rule update_max {
    select when shop update_max_distance
    
    pre{
      max_distance = event:attr("max_distance").as("Number")
    }
    
    always {
      ent:max_distance_in_miles := max_distance
    }
  }
  
  
  rule new_flower_order {
    select when shop new_order
    pre {
      dest = event:attr("destination")
      customer_number = event:attr("customer's number")
      pickup = event:attr("pickup time") || time:now()
      deadline = event:attr("delivery deadline") || time:add(time:new(time:now().substr(0,10)),{"days": 1})
      profile = profile:get_message_profile()
      message = create_new_delivery_request_rumor_message(profile, dest, pickup, deadline, customer_number)
    }
    always {
      ent:message_seq := ent:message_seq + 1
      ent:delivery_seq := ent:delivery_seq + 1
      ent:delivery_requests{message{"Delivery_ID"}} := message
      raise shop event "delivery_request"
        attributes {"message": message}
    }
  }
  
  rule distribute_delivery_request {
    select when shop delivery_request
    foreach subscription:established().filter(function(info){ info{"Tx_role"} == "driver"}) setting(sub)
    pre {
      message = event:attr("message")
    }
    event:send({"eci": sub{"Tx"}, "domain": "driver_gossip", "type": "rumor", "attrs": {"message": message} })
  }
  
  rule incoming_delivery_bid {
    select when shop new_delivery_bid
    pre {
      delivery_id = event:attr("Delivery_ID")
      driver_profile = event:attr("Driver_Profile")
      is_available = ent:drivers_for_deliveries{delivery_id}.isnull()
      result = does_driver_qualify(delivery_id, driver_profile)
      driver_qualifies = result{"qualified"}
      distance = result{"distance"}
      auto_select = profile:get_auto_select()
    }
    if is_available && driver_qualifies then noop()
    fired {
      
      raise shop event "store_potential_bid"
        attributes {
          "Delivery_ID": delivery_id,
          "Driver_Profile": driver_profile,
          "distance": distance
        } if not auto_select
      
      raise shop event "accept_bid"
        attributes {
          "Delivery_ID": delivery_id,
          "Driver_Profile": driver_profile,
          "distance": distance
        } if auto_select
    } else {
      raise shop event "reject_bid"
        attributes {
          "Delivery_ID": delivery_id,
          "Driver_Profile": driver_profile,
          "distance": distance
        }
    }
  }
  
  
  rule store_bid {
    select when shop store_potential_bid
    pre {
      delivery_id = event:attr("Delivery_ID")
      bid_info = event:attrs
    }
    always{
      ent:delivery_bids{delivery_id} := ent:delivery_bids{delivery_id}.defaultsTo([]).append(bid_info)
    }
  }
  
  
  rule reject_bid {
    select when shop reject_bid
    pre {
      delivery_id = event:attr("Delivery_ID")
      driver_profile = event:attr("Driver_Profile")
      distance = event:attr("distance")
      driver_tx = driver_profile{"contact_tx"}
      is_available = ent:drivers_for_deliveries{delivery_id}.isnull()
      reason = is_available => ((distance == ent:max_distance_in_miles) => "Driver not qualified" | "Driver too far out. Try again.") | "Delivery no longer available"
    }
    event:send({"eci": driver_tx, "domain": "driver", "type": "bid_rejected", "attrs":{
      "Delivery_ID": delivery_id,
      "reason": reason
    }})
    
    fired{
      ent:max_distance_in_miles := distance
        if distance > ent:max_distance_in_miles
    }
  }
  
  rule manually_accept_bid {
    select when shop manually_accept_bid
    pre {
      delivery_id = event:attr("delivery_id")
      driver_id = event:attr("driver_id")
      bid_info = ent:delivery_bids{delivery_id}.filter(function(bid){
        bid{["Driver_Profile", "id"]} == driver_id
      }).head().klog("selected driver:")
      driver_profile = bid_info{"Driver_Profile"}
      driver_tx = driver_profile{"contact_tx"}
      distance = bid_info{"distance"}
      message = create_bid_accepted_message(delivery_id, driver_profile{"id"})
    }
    event:send({"eci": driver_tx, "domain": "driver", "type": "bid_accepted", "attrs": message })
    fired{
      ent:max_distance_in_miles := distance
        if distance < ent:max_distance_in_miles
      ent:message_seq := ent:message_seq + 1
      ent:drivers_for_deliveries{delivery_id} := driver_profile
      ent:delivery_bids{delivery_id} := ent:delivery_bids{delivery_id}.filter(function(bid){
        bid{["Driver_Profile", "id"]} != driver_id
      })
      raise shop event "subscribe_recent_driver"
        attributes driver_profile
      raise shop event "reject_remaining_bids"
        attributes bid_info
    }
  }
  
  rule reject_remaining_bids {
    select when shop reject_remaining_bids
    foreach ent:delivery_bids{event:attr("Delivery_ID")} setting(bid)
    pre {
      delivery_id = bid{"Delivery_ID"}
      driver_profile = bid{"Driver_Profile"}.klog("reject driver:")
      distance = bid{"distance"}
    }
    always{
      raise shop event "reject_bid"
        attributes {
          "Delivery_ID": delivery_id,
          "Driver_Profile": driver_profile,
          "distance": distance
        }
      ent:delivery_bids := ent:delivery_bids.delete(delivery_id) on final
    }
  }
  
  rule accept_bid {
    select when shop accept_bid
    pre {
      delivery_id = event:attr("Delivery_ID")
      driver_profile = event:attr("Driver_Profile")
      distance = event:attr("distance")
      driver_tx = driver_profile{"contact_tx"}
      message = create_bid_accepted_message(delivery_id, driver_profile{"id"})
    }
    event:send({"eci": driver_tx, "domain": "driver", "type": "bid_accepted", "attrs": message })
    fired{
      ent:max_distance_in_miles := distance
        if distance < ent:max_distance_in_miles
      ent:message_seq := ent:message_seq + 1
      ent:drivers_for_deliveries{delivery_id} := driver_profile
      raise shop event "subscribe_recent_driver"
        attributes driver_profile
    }
  }
  
  
  rule confirm_delivery_pickup {
    select when shop delivery_picked_up
    pre {
      delivery_id = event:attr("Delivery_ID")
    }
    fired {
      raise shop event "notify_enroute"
        attributes {"Delivery_ID": delivery_id}
    }
  }
  
  rule confirm_delivery_dropoff {
    select when shop delivery_dropped_off
    pre {
      delivery_id = event:attr("Delivery_ID")
      time_delivered = event:attr("time_delivered")
      driver_profile = ent:drivers_for_deliveries{delivery_id}
      message = ent:delivery_requests{delivery_id}
      delivery_deadline = message{"Delivery_Deadline"}
      on_time = time_delivered <= delivery_deadline
    }
    if on_time then noop()
    fired {
      raise shop event "update_rating_on_time_delivery"
        attributes {
          "Driver_Profile": driver_profile
        }
    } else {
      raise shop event "update_rating_late_delivery"
        attributes {
          "Driver_Profile": driver_profile
        }
      }
    finally {
      raise shop event "notify_delivery"
        attributes {"Delivery_ID": delivery_id}
    }
  }
  
  rule update_rating_late_delivery {
    select when shop update_rating_late_delivery
    pre{
      driver_tx = event:attr("Driver_Profile"){"contact_tx"}
      driver_id = event:attr("Driver_Profile"){"id"}
    }
    event:send({"eci":driver_tx, "domain": "driver", "type": "new_rating", "attrs":{
          "driver_id": driver_id,
          "rating": 3
    }})
  }
  
  rule update_rating_on_time_delivery {
    select when shop update_rating_on_time_delivery
    pre{
      driver_tx = event:attr("Driver_Profile"){"contact_tx"}
      driver_id = event:attr("Driver_Profile"){"id"}
    }
    event:send({"eci":driver_tx, "domain": "driver", "type": "new_rating", "attrs":{
          "driver_id": driver_id,
          "rating": 5
    }})
  }
  
  rule notify_customer_delivery {
    select when shop notify_delivery
    pre{
      delivery_id = event:attr("Delivery_ID")
      message = ent:delivery_requests{delivery_id}
      to = message{"Customer_Number"}
      shop_name = message{"Shop_Profile"}{"name"}
      from = profile:get_phone_number()
      twilio_message = <<Your Flowers are here. Thank you for shopping with us! We hope to see you back at #{shop_name} again!>>
    }
    every{
      twilio:send_sms(to, from, twilio_message) setting(content);

      send_directive("response_content", {"content": content})
    }
    
    always {
      ent:delivery_requests := ent:delivery_requests.delete(delivery_id)
      ent:drivers_for_deliveries := ent:drivers_for_deliveries.delete(delivery_id)
    }
  }
  
  rule notify_customer_enroute {
    select when shop notify_enroute
    
    pre{
      delivery_id = event:attr("Delivery_ID")
      driver_name = ent:drivers_for_deliveries{delivery_id}{"name"}
      message = ent:delivery_requests{delivery_id}
      to = message{"Customer_Number"}
      shop_location = message{"Shop_Profile"}{"location"}
      destination = message{"Delivery_Destination"}
      from = profile:get_phone_number()
      time = distance:get_duration(shop_location, destination)
      twilio_message = <<Your Florist, #{driver_name}, will be there in #{time}>>
    }
    every{
      twilio:send_sms(to, from, twilio_message) setting(content);

      send_directive("response_content", {"content": content})
    }
  }
  
  
  
  
  
  
  rule initial_drivers {
    select when shop initial_drivers
    pre {
      num_drivers = event:attr("num_drivers")
      drivers = event:attr("drivers")
    }
    if num_drivers < 1 || drivers.isnull() || num_drivers != drivers.length()
    then noop()
    notfired {
      raise shop event "subscribe_drivers"
        attributes {"drivers": drivers}
    } finally {
      schedule shop event "request_drivers" at time:add(time:now(), {"seconds": need_driver_poll})
        if schedule:list().none(function(act){
          act{"event"}{"domain"} == "shop" && act{"event"}{"type"} == "request_drivers" 
          && engine:getPicoIDByECI(act{"event"}{"eci"}) == meta:picoId
        })
    }
  }
  
  rule subscribe_recent_driver {
    select when shop subscribe_recent_driver
    pre {
      driver_tx = event:attr("wellknown")
      driver_name = event:attr("name")
      already_known = ent:known_driver_names.any(function(n){ n == driver_name })
      known_connection_id = already_known => ent:known_drivers.filter(function(v,k){ v{"name"} == driver_name}).keys().head() | null
      longest_driver = get_longest_driver().klog("longest driver was:")
      at_max = ent:known_driver_names.length() >= max_known_drivers && not already_known
      shop_tx = subscription:wellKnown_Rx()["id"]
    }
    if not already_known then
      event:send({"eci":driver_tx, "domain":"wrangler", "type":"subscription", "attrs":{
              "name" : driver_name,
              "Rx_role": "driver",
              "Tx_role": "shop",
              "channel_type": "subscription",
              "wellKnown_Tx" : shop_tx
            }})
    fired {
      ent:known_driver_names := ent:known_driver_names.append(driver_name)
        if ent:known_driver_names.none(function(d){d == driver_name})
      raise wrangler event "subscription_cancellation"
        attributes {"Id": longest_driver}
          if at_max && not longest_driver.isnull()
    } else {
      ent:known_drivers := ent:known_drivers.set([known_connection_id, "last_delivery"], time:now())
        if not known_connection_id.isnull()
    }
  }
  
  rule subscribe_drivers {
    select when shop subscribe_drivers
      foreach event:attr("drivers") setting(driver)
      pre {
        driver_name = driver{"name"}.klog("Driver name was:")
        eci = driver{"eci"}
        driver_rx = wrangler:skyQuery(eci, "io.picolabs.subscription", "wellKnown_Rx")["id"]
        shop_tx = subscription:wellKnown_Rx()["id"]
      }
      if ent:known_driver_names.none(function(d){ d == driver_name} ) 
        && ent:known_driver_names.length() < max_known_drivers then
          event:send({"eci":driver_rx, "domain":"wrangler", "type":"subscription", "attrs":{
            "name" : driver_name,
            "Rx_role": "driver",
            "Tx_role": "shop",
            "channel_type": "subscription",
            "wellKnown_Tx" : shop_tx
          }})
      fired {
        ent:known_driver_names := ent:known_driver_names.append(driver_name)
          if ent:known_driver_names.none(function(d){d == driver_name})
      }
  }
  
  rule request_drivers {
    select when shop request_drivers
    pre {
      need_drivers = ent:known_driver_names.length() < min_known_drivers
    }
    if need_drivers then 
      event:send({"eci": wrangler:parent_eci(), "domain": "flower_delivery", "type": "need_drivers", "attrs": {
          "name": wrangler:myself(){"name"},
          "eci": wrangler:myself(){"eci"}
        }
      })
  }
  
  rule new_subscription {
    select when wrangler subscription_added
    pre {
      name = event:attr("name")
      id = event:attr("Id")
    }
    always {
      ent:known_drivers{id} := {"name": name, "last_delivery": time:now()}
      ent:known_driver_names := ent:known_driver_names.append(name)
        if ent:known_driver_names.none(function(d){d == name})
    }
  }
  
  rule lost_subscription {
    select when wrangler subscription_removed
    pre {
      lost_id = event:attr("Id")
      was_driver = event:attr("bus"){"Tx_role"} == "driver"
      name = ent:known_drivers{lost_id}{"name"}.klog("name to delete:")
      scheduled_request = schedule:list().any(function(act){
          act{"event"}{"domain"} == "shop" && act{"event"}{"type"} == "request_drivers" 
          && engine:getPicoIDByECI(act{"event"}{"eci"}) == meta:picoId })
    }
    if scheduled_request == false && was_driver 
      && ent:known_driver_names.length() - 1 < min_known_drivers then 
        event:send({"eci": wrangler:parent_eci(), "domain": "flower_delivery", "type": "need_drivers", "attrs": {
            "name": wrangler:myself(){"name"},
            "eci": wrangler:myself(){"eci"}
          }
        })
    always {
      ent:known_driver_names := ent:known_driver_names.filter(function(d){ d != name}).klog("delete result:")
      ent:known_drivers := ent:known_drivers.delete(lost_id)
    }
  }
  
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:known_driver_names := []
        ent:known_drivers := {}
        ent:message_seq := 0
        ent:delivery_seq := 0
        ent:delivery_requests := {}
        ent:drivers_for_deliveries := {}
        ent:max_distance_in_miles := 30
        ent:delivery_bids := {}
    }
  }
  
  rule auto_accept {
    select when wrangler inbound_pending_subscription_added
    always {
      raise wrangler event "pending_subscription_approval" 
        attributes event:attrs;
    }
  }
}
