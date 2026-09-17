require "./crystalline/requires"
require "./crystalline/ext/fix_random_warning"
require "./crystalline/*"

# Backward compatibility for direct invocation
if PROGRAM_NAME.ends_with?("/crystalline") || PROGRAM_NAME == "crystalline"
  Crystalline::CLI.run
end
