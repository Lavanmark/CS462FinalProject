ruleset distance {
  meta {
    configure using api_key = ""
    shares __testing, get_distance, get_duration
    provides get_distance, get_duration
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        // { "name": "get_distance", "args": [ "origin", "destination" ]},
        // { "name": "get_duration", "args": [ "origin", "destination" ]}
      ], "events":[]
    }
    
    base_url = "https://maps.googleapis.com/maps/api/distancematrix/json?units=imperial"
    
    encode_URI = function(address){
      address.replace(re# #g,"+")
    }
    
    get_distance = function(origin, destination){
      // New York City,NY
      // New+York+City,NY
      response = http:get(<<#{base_url}&origins=#{encode_URI(origin)}&destinations=#{encode_URI(destination)}&key=#{api_key}>>);

      distance_in_miles_text = response{"content"}.decode(){"rows"}[0]{"elements"}[0]{"distance"}{"text"}
      distance_in_miles = distance_in_miles_text.split(re# #)[0].as("Number")
      
      distance_in_miles
    }
    
    get_duration = function(origin, destination){
      // New York City,NY
      // New+York+City,NY
      response = http:get(<<#{base_url}&origins=#{encode_URI(origin)}&destinations=#{encode_URI(destination)}&key=#{api_key}>>);

      response{"content"}.decode(){"rows"}[0]{"elements"}[0]{"duration"}{"text"}
    }
  }
}
