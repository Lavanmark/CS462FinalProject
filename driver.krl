ruleset driver {
  meta {
    
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscription
    use module driver_profile alias profile
    
    shares __testing, get_known_peers, get_peers_by_id, get_name, get_available_deliveries, get_current_delivery
    provides get_name
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_known_peers" },
        { "name": "get_peers_by_id" },
        { "name": "get_available_deliveries" },
        { "name": "get_current_delivery" }
      ] , "events":
      [ //{ "domain": "d1", "type": "t1" }
      //, { "domain": "d2", "type": "t2", "attrs": [ "a1", "a2" ] }
      ]
    }
    
    get_known_peers = function() {
      ent:known_peers
    }
    
    get_peers_by_id = function() {
      ent:peer_names_by_id
    }
    
    get_name = function() {
      wrangler:myself(){"name"}
    }
    
    get_available_deliveries = function() {
      ent:available_deliveries
    }
    
    get_current_delivery = function() {
      ent:current_delivery
    }
    
    is_qualified = function(delivery_req) {
      min_driver_rating = delivery_req{"Shop_Profile"}{"min_driver_rating"}
      driver_rating = profile:get_rating().klog("Rating:- ")
      
      driver_rating > min_driver_rating => true | false
    }
    
    min_known_peers = 2
    need_peer_poll = 30
  }
  
  /*****************************************************************************
  
                GENERAL
  
  *****************************************************************************/
  
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:known_peers := []
        ent:peer_names_by_id := {}
        ent:available_deliveries := {}
        ent:current_delivery := null
    }
  }  
  
  
  rule new_delivery_request {
    select when driver new_delivery_request
    pre {
      message = event:attr("message")
      shop_tx = message{"Shop_Profile"}{"contact_tx"}
      delivery_id = message{"Delivery_ID"}
      qualified = is_qualified(message).klog("Is qualified:-")
    }
    if qualified then noop()
    fired {
      ent:available_deliveries{delivery_id} := message.klog("message was")
      raise driver event "make_bid"
        attributes {"shop_tx": shop_tx, "Delivery_ID": delivery_id }
    }
  }
  

  
  
  /*****************************************************************************
  
                BID LOGIC
  
  *****************************************************************************/  
  
  
  rule make_delivery_bid {
    select when driver make_bid
    pre {
      in_delivery = not ent:current_delivery.isnull()
      shop_tx = event:attr("shop_tx")
      delivery_id = event:attr("Delivery_ID")
      driver_profile = profile:get_profile()
    }
    if not in_delivery && not ent:made_bid then
      event:send({"eci":shop_tx, "domain": "shop", "type": "new_delivery_bid", "attrs":{
        "Delivery_ID": delivery_id,
        "Driver_Profile": driver_profile
      }}) 
    fired {
      ent:made_bid := true
    }
  }
  
  rule bid_rejected {
    select when driver bid_rejected
    pre {
      delivery_id = event:attr("Delivery_ID")
      reason = event:attr("reason")
    }
    always{
      ent:available_deliveries := ent:available_deliveries.delete(delivery_id)
      ent:made_bid := false
    }
  }
  
  
  //create_bid_accepted_message = function(delivery_id, driver_id) {
  //   {
  //     "Message_ID": new_message_ID(),
  //     "Type": "Bid_Accepted",
  //     "Delivery_ID": delivery_id,
  //     "Assigned_Driver": driver_id
  //   }
  // }
  rule bid_accepted {
    select when driver bid_accepted
    pre {
      message = event:attrs
      delivery_id = event:attr("Delivery_ID")
      driver_id = event:attr("Assigned_Driver")
      delivery = ent:available_deliveries{delivery_id}
    }
    if driver_id == meta:picoId /*&& not delivery.isnull()*/ then noop()
    fired{
      ent:current_delivery := delivery
      ent:made_bid := false
      ent:available_deliveries := ent:available_deliveries.delete(delivery_id)
      raise driver_gossip event "rumor"
        attributes {"message": message}
      raise driver event "delivery_picked_up"
        attributes {
          "message": message,
          "Delivery_ID": delivery_id,
          "driver_id": driver_id
        }
    }
  }
  
  rule confirm_delivery_pickup {
    select when driver delivery_picked_up
    pre {
      message = event:attr("message")
      driver_id = event:attr("driver_id")
      delivery_id = event:attr("Delivery_ID")
      shop_profile = message{"Shop_Profile"}
      shop_location = shop_profile{"location"}
      shop_tx = shop_profile{"contact_tx"}
    }
    if driver_id == meta:picoId then 
      event:send({"eci":shop_tx, "domain": "shop", "type": "delivery_picked_up", "attrs":{
          "Delivery_ID": delivery_id,
      }})
    fired {
      raise driver event "location_updated"
        attributes {"location": shop_location}
      raise driver event "delivery_dropped_off"
        attributes event:attrs
    }
  }
  
  rule confirm_delivery_dropoff {
    select when driver delivery_dropped_off
    pre {
      delivery_id = event:attr("Delivery_ID")
      shop_tx = message{"Shop_Profile"}{"contact_tx"}
      destination = message{"Delivery_Destination"}
    }
    if driver_id == meta:picoId then 
      event:send({"eci":shop_tx, "domain": "shop", "type": "delivery_dropped_off", "attrs":{
          "Delivery_ID": delivery_id,
          "time_delivered": time:now()
      }})
    fired {
      ent:current_delivery := null

      raise driver event "location_updated"
        attributes {"location": destination}
    }
  }
  
  rule update_rating {
    select when driver new_rating
    pre{
      rating = event:attr("rating")
      driver_id = event:attr("driver_id")
    }
    if driver_id == meta:picoId then noop()
    fired {
      raise driver event "update_rating"
        attributes {"rating": rating}
    }
  }
  
  rule delivery_taken {
    select when driver delivery_taken
    pre {
      message = event:attr("message")
      delivery_id = message{"Delivery_ID"}
      delivery = ent:available_deliveries{delivery_id}
    }
    if not delivery.isnull() then noop()
    fired{
      ent:available_deliveries := ent:available_deliveries.delete(delivery_id)
    }
  }
  
  
  
  
  
  
  /*****************************************************************************
  
                PEER MANAGEMENT
  
  *****************************************************************************/
  
  rule initial_peers {
    select when driver initial_peers
    pre {
      num_peers = event:attr("num_peers")
      peers = event:attr("peers")
    }
    if num_peers < 1 || peers.isnull() || num_peers != peers.length()
    then noop()
    notfired {
      raise driver event "subscribe_peers"
        attributes {"peers": peers}
    } finally {
      schedule driver event "request_peers" at time:add(time:now(), {"seconds": need_peer_poll})
    }
  }
  
  rule subscribe_peers {
    select when driver subscribe_peers
      foreach event:attr("peers") setting(peer)
      pre {
        peer_name = peer{"name"}.klog("Peer name was:")
        eci = peer{"eci"}
        peer_rx = wrangler:skyQuery(eci, "io.picolabs.subscription", "wellKnown_Rx")["id"]
        my_tx = subscription:wellKnown_Rx()["id"]
      }
      if ent:known_peers.none(function(p){ p == peer_name} ) then
        event:send({"eci":peer_rx, "domain":"wrangler", "type":"subscription", "attrs":{
          "name" : peer_name,
          "Rx_role": "peer",
          "Tx_role": "peer",
          "channel_type": "subscription",
          "wellKnown_Tx" : my_tx
        }})
      fired {
        ent:known_peers := ent:known_peers.append(peer_name)
      }
  }
  
  rule request_peers {
    select when driver request_peers
    pre {
      need_peers = ent:known_peers.length() < min_known_peers
    }
    if need_peers then 
      event:send({"eci": wrangler:parent_eci(), "domain": "flower_delivery", "type": "need_peers", "attrs": {
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
      eci = event:attr("Tx")
      is_peer = event:attr("Tx_role") == "peer"
      made_by_peer = get_name() == name
      final_name = is_peer && made_by_peer => wrangler:skyQuery(eci, "driver", "get_name") | name
    }
    if is_peer then noop()
    fired {
      ent:peer_names_by_id{id} := final_name
      ent:known_peers := ent:known_peers.append(final_name)
        if ent:known_peers.none(function(d){d == final_name})
    }
  }
  
  rule lost_subscription {
    select when wrangler subscription_removed
    pre {
      lost_id = event:attr("Id")
      was_peer = event:attr("bus"){"Tx_role"} == "peer"
      name = ent:peer_names_by_id{lost_id}.klog("name to delete:")
      scheduled_request = schedule:list().any(function(act){
          act{"event"}{"domain"} == "driver" && act{"event"}{"type"} == "request_peers" 
          && engine:getPicoIDByECI(act{"event"}{"eci"}) == meta:picoId })
    }
    if scheduled_request == false && was_peer 
      && ent:known_peers.length() - 1 < min_known_peers then 
        event:send({"eci": wrangler:parent_eci(), "domain": "flower_delivery", "type": "need_peers", "attrs": {
            "name": wrangler:myself(){"name"},
            "eci": wrangler:myself(){"eci"}
          }
        })
    always {
      ent:known_peers := ent:known_peers.filter(function(d){ d != name}).klog("delete result:")
        if was_peer
      ent:peer_names_by_id := ent:peer_names_by_id.delete(lost_id)
        if was_peer
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
