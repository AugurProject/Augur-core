#A consensus guide:
#i) check report validity (1-2 binary, if someone gives a value > or < scalar range or > or < categorical num outcomes, round up/down to 0 or 1 respectively) - done
#    i.i) make sure no blank reports in a ballot - done
#ii) convert scalar / categorical to range 0-1 when submitting report - done
#    iia) if scalar/categorical is a real .5 convert to .5*2^64+1, if indeterminate keep as .5*2^64 - in UI
#    iib) if scalar/categorical is a real 0 convert to 0*2^64+1, else if no response, keep as 0 - in UI
#1) do clustering - done
#    1a) completely missing ballots should just not be clustered - find distance for one of them, penalize the rest accordingly - irrelevant now
#2) normalize to 1 and get new "this" rep vector - done
#    2a) prior to this, multiply by prev. rep vector over mean - done
#    2b) take old rep multiply by .80 add to new rep *.2 (smoothing part) - done
#3) using this, calc. outcomes 1, 1.5, 2 for binary using weighed avg / catch param (.1 or .15) - done
#    3a) scalar outcomes & categoricals use weighted mode - /done
#    3b) if .5 due to catch param push back once (as .5 outcome), if same on next consensus no more push backs, # that's the outcome (or we could audit here or do certainty based audits) - done
#    3c) detect b via a "times voted on" var - done
#    3d) when doing outcomes, only do weighted avg / mode on people who actually reported on that event, i.e. # don't include people who reported 0 / no report - done
#    #note: do outcomes w/ smooth rep (not just "new rep"), and calculate using tolerance, use weighted med. for scalars - done
#    #3e) then scale scaled back up to w/e value - ditto for categorical (need to mult by range and add min i think) for categorical range is numOutcomes - 1, min is 1 - done
#    #3f) save outcomes - done
#4) Payout reporters & event bonds - done
