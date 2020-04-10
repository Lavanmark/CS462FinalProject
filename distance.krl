ruleset distance {
    meta {
      configure using api_key = ""
      shares __testing, get_distance
      provides get_distance
    }
    global {
      __testing = { "queries":
        [ { "name": "__testing" },
          { "name": "get_distance"}
        ], "events":[]
      }
      
      base_url = "https://maps.googleapis.com/maps/api/distancematrix/json?units=imperial"
      
      encode_URI = function(address){
        address.replace(re# #g,"+")
      }
      
      get_distance = function(origin, destination){
        // New+York+City,NY
        // response = http:get(<<#{base_url}&origins=#{encode_URI(origin)}&destinations=#{encode_URI(destination)}&key=#{api_key}>>);
  
        // response{"content"}.decode()
        10
      }
    }
  }
  