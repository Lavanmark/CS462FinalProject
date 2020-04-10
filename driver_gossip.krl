ruleset driver_gossip {
  meta {
    use module io.picolabs.subscription alias subscription
    shares __testing, get_rumors_received, get_seen_tracker, get_my_latest, get_is_processing
  }
  global {
    
    
    
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_rumors_received"},
        { "name": "get_seen_tracker"},
        { "name": "get_my_latest"},
        { "name": "get_is_processing"}
      ] , "events":
      [ { "domain": "driver_gossip", "type": "update_heartrate", "attrs": ["heartbeat_rate"] },
        { "domain": "driver_gossip", "type": "process" },
        { "domain": "driver_gossip", "type": "process", "attrs": ["process"] }
      ]
    }
    
    get_rumors_received = function() {
      ent:rumors_recv
    }
    
    get_seen_tracker = function() {
      ent:seen_tracker
    }
    
    get_my_latest = function() {
      ent:my_latest
    }
    
    get_is_processing = function() {
      ent:do_process
    }
    
    get_state = function(seen) {
      ent:rumors_recv.filter(function(v){
        id = get_picoID(v{"Message_ID"})
        seen{id}.isnull() || (seen{id} < get_sequence(v{"Message_ID"}))
      }).sort(function(a,b){
        aseq = get_sequence(a{"Message_ID"})
        bseq = get_sequence(b{"Message_ID"})
        aseq <=> bseq
      })
    }
    
    
    getPeer = function() {
      subs = subscription:established("Rx_role", "peer")

      frens_in_need = ent:seen_tracker.filter(function(v,k){
        get_state(v).length() > 0
      })
      
      rand_fren = frens_in_need.keys()[random:integer(frens_in_need.length() - 1)]
      frens_in_need.length() < 1 => subs[random:integer(subs.length() - 1)] | subs.filter(function(a){a{"Tx"} == rand_fren}).head()
    }
    
    
    get_best_sequence = function(pico) {
      filter_rumors = ent:rumors_recv.filter(function(v){
        id = get_picoID(v{"Message_ID"})
        id == pico
      }).map(function(v){get_sequence(v{"Message_ID"})})
      sorted_rumors = filter_rumors.sort(function(a,b){a<=>b}).klog("sorted array: ")
      sorted_rumors.reduce(function(a, b) { (b == a + 1) => b | a }, -1)
    }
    
    
    prepareMessage = function(subscriber) {
      message = random:integer(10) < 6 => prepare_rumor(subscriber) | prepare_seen(subscriber)
      message = message{"message"}.isnull() => prepare_seen(subscriber) | message
      message
    }
    
    prepare_rumor = function(subscriber) {
      missing_rumor = get_state(ent:seen_tracker{subscriber{"Tx"}})
      return { "message": missing_rumor.isnull() => null | missing_rumor.head(),
               "type": "rumor" }
    }
    
    prepare_seen = function(subscriber) {
      return {"message": ent:my_latest, 
              "sender": subscriber,
              "type": "seen"} 
    }
    
    get_sequence = function(message_id){
     splits = message_id.split(re#:#)
     splits[splits.length()-1].as("Number")
    }
    
    get_picoID = function(message_id){
     splits = message_id.split(re#:#)
     splits[0]
    }
  }
  
  rule update_rate {
    select when driver_gossip update_heartrate
    pre{
      new_rate = event:attr("heartbeat_rate")
    }
    if not new_rate.isnull() then noop()
    fired {
      ent:heartbeat_rate := new_rate
    }
  }
  
  rule do_process_toggle {
    select when driver_gossip process
    pre{
      process = event:attr("process")
    }
    if process.isnull() || (process != "on" && process != "off") then noop()
    fired { //toggle
      ent:do_process := ent:do_process == "on" => "off" | "on"
    } else { //set
      ent:do_process := process
    } finally { //if do_process is on, restart the driver_gossip heartbeat.
      schedule driver_gossip event "heartbeat" at time:add(time:now(), {"seconds": ent:heartbeat_rate})
        if ent:do_process == "on" && schedule:list().klog("schedule:").none(function(act){ engine:getPicoIDByECI(act{"event"}{"eci"}) == meta:picoId && act{"event"}{"domain"} == "driver_gossip" && act{"event"}{"type"} == "heartbeat"})
    }
  }
  
  rule driver_gossip_heartbeat {
    select when driver_gossip heartbeat where ent:do_process == "on"
    pre {
      subscriber = getPeer().klog("Subscriber info:")
      m = prepareMessage(subscriber)
      message_pico = get_picoID(m{"message"}{"Message_ID"})
      message_seq = get_sequence(m{"message"}{"Message_ID"})
    }
    if subscriber.isnull() == false && m.isnull() == false then 
      event:send({
          "eci": subscriber{"Tx"},
          "domain": "driver_gossip", 
          "type": m{"type"}.klog("Message type being sent:"),
          "attrs": m
      })
    fired{ 
      ent:seen_tracker{[subscriber{"Tx"}, message_pico]} :=  message_seq
        if m{"type"} == "rumor" && 
          ((ent:seen_tracker{subscriber{"Tx"}}{message_pico}.isnull() && message_seq == 0) || 
            ent:seen_tracker{subscriber{"Tx"}}{message_pico} + 1 == message_seq)
    }finally{
      schedule driver_gossip event "heartbeat" at time:add(time:now(), {"seconds": ent:heartbeat_rate})
    }
  }
  
  rule driver_gossip_request_rumor {
    select when driver_gossip rumor where ent:do_process == "on"
    pre {
      message = event:attr("message")
      message_id = message{"Message_ID"}
      pico = get_picoID(message_id)
      sequence = get_sequence(message_id)
      is_new = ent:rumors_recv.none(function(x){x{"Message_ID"} == message_id })
    }
    if ent:my_latest{pico}.isnull() then noop()
    fired {
      ent:my_latest{pico} := -1
    } finally {
      ent:rumors_recv := ent:rumors_recv.append(message)
        if is_new
      
      ent:my_latest{pico} := get_best_sequence(pico)
      
      raise driver event "new_delivery_request"
        attributes {"message": message}
          if is_new && message{"Type"} == "Delivery_Request"
      raise driver event "delivery_taken"
        attributes {"message": message}
          if is_new && message{"Type"} == "Bid_Accepted"
    }
  }
  
  rule driver_gossip_seen {
    select when driver_gossip seen where ent:do_process == "on"
    pre {
      sender = event:attr("sender"){"Rx"}
      message = event:attr("message")
    }
    always {
      ent:seen_tracker{sender} := message
    }
  }
  
  rule store_new_gossiper_subscription {
    select when wrangler subscription_added
    pre {
      tx_role = event:attr("bus")["Tx_role"].klog("tx role: ")
      tx = event:attr("bus")["Tx"].klog("tx: ")
    }
    if tx_role == "peer" then 
      noop()
    fired{
      ent:seen_tracker{tx} := {}
    }
  }
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:heartbeat_rate := 3;
        ent:rumors_recv := [];
        ent:my_latest := {}
        ent:seen_tracker := {} //map of peer_Tx to a map of PicoIDs to latest seen message sequence number
        ent:do_process := "on"
        schedule driver_gossip event "heartbeat" at time:add(time:now(), {"seconds": 10})
    }
  }
}
