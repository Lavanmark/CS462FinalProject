ruleset driver {
  meta {
    
    use module io.picolabs.wrangler alias wrangler
    use module io.picolabs.subscription alias subscription
    
    shares __testing, get_known_peers, get_peers_by_id, get_name
    provides get_name
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_known_peers" },
        { "name": "get_peers_by_id" }
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
    
    min_known_peers = 2
    need_peer_poll = 30
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
  
  
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:known_peers := []
        ent:peer_names_by_id := {}
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
