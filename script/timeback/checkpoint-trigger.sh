#!/usr/bin/env bash

# Return one trigger value for a pass. The caller checkpoints once regardless of
# whether one or both thresholds became true during the same poll.
checkpoint_trigger() {
  local start_edges="$1"
  local current_edges="$2"
  local elapsed_seconds="$3"
  local edge_interval="$4"
  local time_interval_seconds="$5"
  local edge_due=false time_due=false

  if (( current_edges - start_edges >= edge_interval )); then
    edge_due=true
  fi
  if (( elapsed_seconds >= time_interval_seconds )); then
    time_due=true
  fi

  if [ "$edge_due" = true ] && [ "$time_due" = true ]; then
    echo edges+time
  elif [ "$edge_due" = true ]; then
    echo edges
  elif [ "$time_due" = true ]; then
    echo time
  else
    echo none
  fi
}
