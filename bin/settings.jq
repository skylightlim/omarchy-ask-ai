# The send settings from the Ask AI panel, NUL-separated so prompts keep
# their newlines: url, title match, prompt, submit (1/0), load timeout,
# submit delay, special workspace (1/0), AI name, answer in a card (1/0;
# on unless turned off). Inputs: $d default config, $c user config, $s saved state
# (each via --slurpfile).
#
# The AI used last (else the first); its saved pre-prompt (else the user's
# own text; the first pre-prompt on a first run); and whether to press Enter.
($d[0] // {}) as $def | ($c[0] // {}) as $cfg | ($s[0] // {}) as $st
| (if ($cfg.targets | type) == "array" and ($cfg.targets | length) > 0 then $cfg.targets else $def.targets end) as $targets
| (if ($cfg.prompts | type) == "array" then $cfg.prompts else ($def.prompts // []) end) as $prompts
| (first($targets[] | select(.name == $st.target)) // $targets[0]) as $t
| (if $st.target == null then ($prompts[0].text // "")
   elif ($st.prompt // "") != "" then ((first($prompts[] | select(.name == $st.prompt)) | .text) // ($st.custom // ""))
   else ($st.custom // "") end) as $p
| [ $t.url // "", $t.match // "", $p,
    (if $st.submit == true then "1" else "0" end),
    ($cfg.loadTimeout // $def.loadTimeout // 10), ($cfg.submitDelay // $def.submitDelay // 2.5),
    (if $st.special == true then "1" else "0" end),
    $t.name // "",
    (if $st.card == false then "0" else "1" end) ]
| map(tostring + "\u0000") | add
