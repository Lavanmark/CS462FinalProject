ruleset shop {
  meta {
    use module shop_keys
    use module customer_communication alias twilio
      with account_sid = keys:twilio{"account_sid"}
      auth_token = keys:twilio{"auth_token"}
    
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscription
    
    shares __testing, get_known_drivers, get_known_driver_names, get_schedule
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_known_drivers" },
        { "name": "get_known_driver_names"},
        { "name": "get_schedule"}
      ] , "events":
      [ //{ "domain": "d1", "type": "t1" }
      //, { "domain": "d2", "type": "t2", "attrs": [ "a1", "a2" ] }
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
    
    create_new_delivery_request_rumor_message = function(profile, destination, pickup_time, deadline) {
      {
        "Message_ID": new_message_ID(),
        "Type": "Delivery_Request",
        "Delivery_ID": new_delivery_ID(),
        "Shop_Profile": profile,
        "Delivery_Destination": destination,
        "Pickup_Time": time,
        "Delivery_Deadline": deadline
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
    
    max_known_drivers = 5
    min_known_drivers = 2
    need_driver_poll = 30
  }
  
  
  
  rule new_flower_order {
    select when shop new_order
    pre {
      dest = event:attr("destination")
      pickup = event:attr("pickup time")
      deadline = event:attr("delivery deadline")
    }
  }
  
  rule notify_customer_delivery {
    select when shop notify_delivery
  }
  
  rule notify_customer_enroute {
    select when shop notify_enroute
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
