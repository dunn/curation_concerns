json.extract! @generic_file, *[:id] + @generic_file.class.fields.select {|f| ![:has_model].include? f}