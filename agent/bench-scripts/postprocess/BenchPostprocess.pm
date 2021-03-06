#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: t; perl-indent-level: 8 -*-

# Author: Andrew Theurer

package BenchPostprocess;

use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';
use Exporter qw(import);
use List::Util qw(max);
use JSON;

our @EXPORT_OK = qw(value_exists trim_series get_label create_uid get_length get_uid get_mean remove_timestamp get_timestamps write_influxdb_line_protocol get_cpubusy_series calc_ratio_series calc_sum_series div_series calc_aggregate_metrics calc_efficiency_metrics create_graph_hash get_json);

my $script = "BenchPostprocess";

# always use this for labels in the hashes for JSON data
sub get_label {
	my $key = shift;
	my %labels = (
			'port_label' => 'port',
			'uid_label' => 'uid',
			'description_label' => 'description',
			'role_label' => 'role',
			'hostname_label' => 'hostname',
			'client_hostname_label' => 'client_hostname',
			'server_hostname_label' => 'server_hostname',
			'server_port_label' => 'server_port',
			'value_label' => 'value',
			'timeseries_label' => 'timeseries',
			'date_label' => 'date',
			'benchmark_name_label' => 'benchmark_name',
			'benchmark_version_label' => 'benchmark_version',
			'test_type_label' => 'test_type',
			'message_size_bytes_label' => 'message_size_bytes',
			'block_size_kbytes_label' => 'block_size_kbytes',
			'instances_label' => 'instances',
			'clients_label' => 'clients',
			'servers_label' => 'servers',
			'port_label' => 'port',
			'controller_host_label' => 'controller_host',
			'protocol_label', => 'protocol',
			'server_port_label' => 'server_port',
			'mean_label' => 'mean',
			'stddev_label' => 'stddev',
			'stddevpct_label' => 'stddevpct',
			'closest_sample_label' => 'closest_sample',
			'samples_label' => 'samples',
			'primary_metric_label' => 'primary_metric',
			'max_stddevpct_label' => 'max_stddevpct',
			'max_failures_label' => 'max_failures',
			'skip_aggregate_label' => 'skip_aggregate',
			'rw_label' => 'read_or_write' );
	if ( $labels{$key} ) {
		return $labels{$key}
	} else {
		print "warning: you tried to use a non-standard label [$key]\n";
	}
}

sub create_uid {
	my $uid;
	foreach my $label (@_) {
		if ( $uid ) {
			$uid = $uid . "-" . get_label($label) . ':%' . get_label($label) . '%';
		} else {
			$uid = get_label($label) . ':%' . get_label($label) . '%';
		}
	}
	return $uid;
}

sub get_length {
	my $text = shift;
	return scalar split("", $text)
}

# read a json file and put in hash
# the return value is a reference
sub get_json {
	my $perl_scalar = 0;
	my $filename = shift;
	if (open(JSON, "<:encoding(UTF-8)", $filename)) {
		my $json_text = "";
		my $junk_mode = 1;
		while ( <JSON> ) {
			if ($junk_mode) {
				if ( /(.*)(\{.*)/ ) { # ignore any junk before the "{"
					$junk_mode = 0;
					my $junk = $1;
					my $not_junk = $2;
					$json_text = $json_text . $not_junk;
				}
			} else {
				$json_text = $json_text . $_;
			}
		}
		close JSON;
		if ($json_text eq "") {
			print "Empty contents for \'$filename\'\n";
		} else {
			$perl_scalar = from_json($json_text);
		}
	} else {
		print "Could not open \'$filename\'\n";
	}
	return $perl_scalar;
}

sub get_uid {
	my $uid = shift;
	my $uid_sources_ref = shift;
	my $mapped_uid = "";
	while ( $uid && $uid =~ s/^([^%]*)%([^%]+)%// ) {
		my $before_uid_marker = $1;
		my $uid_marker = $2;
		if ( exists $$uid_sources_ref{$uid_marker} ) {
			$mapped_uid = $mapped_uid . $before_uid_marker . $$uid_sources_ref{$uid_marker};
		} else {
			$mapped_uid = $mapped_uid . $before_uid_marker . "%" . $uid_marker . "%";
		}
	}
	# for any text left over after all markers have been found
	if ($uid) {
		$mapped_uid = $mapped_uid . $uid;
	}
	return $mapped_uid;
}

# in a array of { 'date' => x, 'value' => y } hashes, return the average of all y's
sub get_mean {
	my $array_ref = shift;
	my $total = 0;
	my $i;
	for ($i=0; $i < scalar @{ $array_ref }; $i++) {
		$total += $$array_ref[$i]{'value'};
	}
	if ( $i > 0 ) {
		return $total / $i;
	}
}

# in a array of { 'date' => x, 'value' => y } hashes, find the hash which $timestamp matchs x and then return y
sub get_value {
	my $array_ref = shift;
	my $timestamp = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		if ( $$timestamp_value_ref{'date'} == $timestamp ) {
			return $$timestamp_value_ref{'value'};
		}
	}
}

# in a array of { 'date' => x, 'value' => y } hashes, either find the hash which $timestamp matchs x and update y, or
# if there is no hash which $timestamp matches x, add a new hash
sub put_value {
	my $array_ref = shift;
	my $timestamp = shift;
	my $value = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		if ( $$timestamp_value_ref{'date'} == $timestamp ) {
			$$timestamp_value_ref{'value'} = $value;
			return;
		}
	}
	my %timestamp_value = ('date' => $timestamp, 'value' => $value);
	push(@{ $array_ref }, \%timestamp_value);
}

# in a array of { 'date' => x, 'value' => y } hashes, find the hash which $timestamp matchs x and then remove that hash from the array
sub remove_timestamp {
	my $array_ref = shift;
	my $timestamp = shift;
	my $found = 0;
	my $i;
	for ($i=0; $i < scalar @{ $array_ref }; $i++) {
		if ( $$array_ref[$i]{'date'} == $timestamp ) {
			splice(@$array_ref, $i, 1);
			$found = 1;
		}
	}
	return $found;
}

# in a array of { 'date' => x, 'value' => y } hashes, return an array of only timestamps
sub get_timestamps {
	my @timestamps;
	my $array_ref = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		push(@timestamps, $$timestamp_value_ref{'date'});
	}
	return @timestamps = sort {$a<=>$b} @timestamps;
}

sub trim_series {
	my $array_ref = shift;
	my $begin_trim = shift;
	my $end_trim = shift;
	my @timestamps = get_timestamps($array_ref);
	my $timestamp;

	if ( $begin_trim > 0 and scalar @timestamps) {
		my $first_timestamp = shift(@timestamps);
		$timestamp = $first_timestamp;
		while ( ($timestamp - $first_timestamp) <= ($begin_trim * 1000) and remove_timestamp($array_ref, $timestamp)) {
			if (scalar @timestamps) {
				$timestamp = shift(@timestamps);
			}
		}
	}

	if ( $end_trim > 0 and scalar @timestamps) {
		my $last_timestamp = pop(@timestamps);
		$timestamp = $last_timestamp;
		while ( ($last_timestamp - $timestamp) <= ($end_trim * 1000) and remove_timestamp($array_ref, $timestamp)) {
			if (scalar @timestamps) {
				$timestamp = pop(@timestamps);
			}
		}
	}
}

sub write_influxdb_line_protocol {
	my $params = shift;
	# the name of the measurement, like resource_cpu_busy or benchmark_throughput_Gb_sec
	my $measurement = $params;
	# the directory to write this file
	$params = shift;
	my $dir = $params;
	$params = shift;
	# These hash, which will be populated with cpubusy data, needs to be used by reference in order to preserve the changes made
	my $data_ref = $params;
	my $file_name = $dir . "/" . $measurement . ".txt";
	if (open(INFLUXDB, ">>$file_name")) {
		my $timestamp;
		foreach $timestamp (keys %{ $$data_ref{get_label('timeseries_label')} } ) {
			my $this_key;
			my $id_string = $measurement;
			foreach $this_key (keys %{ $data_ref}) {
				if ( $this_key ne get_label('timeseries_label') && $this_key ne "uid" && $this_key ne "value" && $this_key ne "description" && $$data_ref{$this_key}) {
					my $value = $$data_ref{$this_key};
					$value =~ s/\s/\\ /g;
					$id_string = $id_string . "," . $this_key . "=" . $value;
				}
			}
		my $timestamp_ns = $timestamp * 1000000;
		my $value = $$data_ref{get_label('timeseries_label')}{$timestamp};
		printf INFLUXDB "%s value=%f %d\n", $id_string, $value, $timestamp_ns;
		}
		close(INFLUXDB);
	}
}
sub get_cpubusy_series {
	# This will get a hash (series) with keys = timestamps and values = CPU busy
	# CPU Busy is in CPU units: 1.0 = amoutn of cpu used is equal to 1 logical CPU
	# 1.0 does not necessarily mean exactly 1 of the cpus was used at 100%.
	# This value is a sum of all cpus used, which may be several cpus used, each a fraction of their maximum

	my $first_timestamp;
	my $last_timestamp;
	my $params = shift;
	# This is the directory which contains the tool data: see ./sar/csv/cpu_all_cpu_busy.csv
	my $tool_dir = $params;
	$params = shift;
	# These hash, which will be populated with cpubusy data, needs to be used by reference in order to preserve the changes made
	my $cpu_busy_ref = $params;
	$params = shift;
	if ($params) {
		# We don't want data before this timestamp
		$first_timestamp = $params;
		$params = shift;
		if ($params) {
			# We don't want data after this timestamp
			$last_timestamp = $params;
		}
	}
	my $file = "$tool_dir/sar/csv/cpu_all_cpu_busy.csv";
	if (open(SAR_ALLCPU_CSV, "$file")) {
		my $timestamp_ms = 0;
		my @values;
		my $cpu_busy;
		my $cnt = 0;
		while (my $line = <SAR_ALLCPU_CSV>) {
			chomp $line;
			## The csv file has this format:
			# timestamp_ms,cpu_00,cpu_01,cpu_02,cpu_03
			# 1429213202000,10.92,6.9,5,6.66
			# 1429213205000,88.29,0.33,0.67,0
			if ( $line =~ /^timestamp/ ) {
				next;
			}
			@values = split(/,/,$line);
			$timestamp_ms = shift(@values);
			if ((!$last_timestamp || $timestamp_ms <= $last_timestamp ) && ( !$first_timestamp || $timestamp_ms >= $first_timestamp )) {
				my $value;
				$cpu_busy = 0;
				foreach $value (@values) {
					$cpu_busy += $value;
				}
				push(@$cpu_busy_ref, { 'date' => int $timestamp_ms, 'value' => $cpu_busy/100});
				$cnt++;
			}
		}
		close(SAR_ALLCPU_CSV);
		if ($cnt > 0) {
			return 0;
		} else {
			printf "$script: no sar timestamps in $file fall within given range: $first_timestamp - $last_timestamp\n";
			return 1;
		}
	} else {
		printf "$script: could not find file $file\n";
		return 1;
	}
}

sub calc_ratio_series {
	# This generates a new hash (using the hash referfence, $ratio) from two existing hashes
	# (hash references $numerator and $denominator).  This is essentially:
	# %ratio_hash = %numerator_hash / %denominator_hash
	# Each hash is a time series, with a value for each timestamp key
	# The timestamp keys do not need to match exactly.  Values are interrepted linearly


	# These hashes need to be used by reference in order to preserve the changes made
	my $params = shift;
	my $numerator = $params;
	$params = shift;
	my $denominator = $params;
	$params = shift;
	my $ratio = $params;

	# This would be fairly trivial if the two hashes we are dealing with had the same keys (timestamps), but there
	# is no guarantee of that.  What we do is key off the timestamps of the second hash and interpolate a value from the first hash.
	my $count = 0;
	my $prev_numerator_timestamp_ms = 0;
	my @numerator_timestamps = get_timestamps($numerator);
	if ( scalar @numerator_timestamps == 0 ) {
		print "warning: no timestamps found for numerator in calc_ratio_series()\n";
		return 1;
	}
	my @denominator_timestamps = get_timestamps($denominator);
	if ( scalar @denominator_timestamps == 0 ) {
		print "warning: no timestamps found for denominator in calc_ratio_series()\n";
		return 2;
	}
	while ($denominator_timestamps[0] and $numerator_timestamps[0] and $denominator_timestamps[0] < $numerator_timestamps[0]) {
		shift(@denominator_timestamps) || last;
	}
	# remove any "trailing" timestamps: timestamps from denominator that come after the last timestamp in numerator
	while ($denominator_timestamps[-1] and $numerator_timestamps[-1] and $denominator_timestamps[-1] >= $numerator_timestamps[-1]) {
		my $unneeded_denominator_timestamp = pop(@denominator_timestamps);
		remove_timestamp(\@{ $denominator }, $unneeded_denominator_timestamp);
	}
	my $numerator_timestamp_ms = shift(@numerator_timestamps);
	my $denominator_timestamp_ms;
	for $denominator_timestamp_ms (@denominator_timestamps) {
		# don't attempt to calculate a ratio if we have divide by zero
		if (get_value($denominator, $denominator_timestamp_ms) == 0) {
			next;
		}
		# find a pair of consecutive numerator timestamps which are before & after the denominator timestamp
		# these timestamps are ordered, so once the first numerator timestamp is found that is >= denominator timestamp,
		# the previous numerator timestamp should be < denominator timestamp.
		while ($numerator_timestamp_ms <= $denominator_timestamp_ms) {
			$prev_numerator_timestamp_ms = $numerator_timestamp_ms;
			$numerator_timestamp_ms = shift(@numerator_timestamps) || last;
		}
		my $numerator_value_base = get_value($numerator, $prev_numerator_timestamp_ms);
		my $denominator_prev_numerator_timestamp_diff_ms = ($denominator_timestamp_ms - $prev_numerator_timestamp_ms);
		my $value_adj = 0;
		if ($denominator_prev_numerator_timestamp_diff_ms != 0) {
			my $numerator_prev_numerator_timestamp_diff_ms = ($numerator_timestamp_ms - $prev_numerator_timestamp_ms);
			my $value_diff = get_value($numerator, $numerator_timestamp_ms) - $numerator_value_base;
			$value_adj = $value_diff * $denominator_prev_numerator_timestamp_diff_ms/$numerator_prev_numerator_timestamp_diff_ms;
		}
		my $numerator_value_interp = $numerator_value_base + $value_adj;
		put_value($ratio, $denominator_timestamp_ms, $numerator_value_interp/get_value($denominator, $denominator_timestamp_ms));
		$count++;
	}
}

sub calc_sum_series {
	# This takes the sum of two hashes (hash references $add_from_ref and $add_to_ref)
	# and stores the values in $add_to_ref.  This is essentially:
	# %add_to_hash = %add_from_hash + %add_to_hash
	# Each hash is a time series, with a value for each timestamp key
	# The timestamp keys do not need to match exactly.  Values are interrepted linearly
	# These hashes need to be used by reference in order to preserve the changes made
	my $params = shift;
	my $add_from_ref = $params;
	$params = shift;
	my $add_to_ref = $params;
	# This would be fairly trivial if the two hashes we are dealing with had the same keys (timestamps), but there
	# is no guarantee of that.  What we have to do is key off the timestamps of the second hash (where we store the sum)
	# and interpolate a value from the first hash.
	my $count = 0;
	my $prev_stat1_timestamp_ms = 0;
	my @stat1_timestamps = get_timestamps(\@{$add_from_ref});
	my @stat2_timestamps = get_timestamps(\@{$add_to_ref});
	# remove any "leading" timestamps: timestamps from stat2 that come before first timestamp in stat1
	while ($stat2_timestamps[0] and $stat1_timestamps[0] and $stat2_timestamps[0] < $stat1_timestamps[0]) {
		my $unneeded_stat2_timestamp = shift(@stat2_timestamps);
		remove_timestamp (\@{ $add_to_ref}, $unneeded_stat2_timestamp) || last;
	}
	# remove any "trailing" timestamps: timestamps from stat2 that come after the last timestamp in stat1
	while ($stat2_timestamps[-1] and $stat1_timestamps[-1] and $stat2_timestamps[-1] > $stat1_timestamps[-1]) {
		my $unneeded_stat2_timestamp = pop(@stat2_timestamps);
		remove_timestamp(\@{ $add_to_ref}, $unneeded_stat2_timestamp) || last;
	}
	if (scalar @stat1_timestamps) {
		my $stat1_timestamp_ms = shift(@stat1_timestamps);
		my $stat2_timestamp_ms;
		for $stat2_timestamp_ms (@stat2_timestamps) {
			# find a pair of consecutive stat1 timestamps which are before & after the stat2 timestamp
			# these timestamps are ordered, so once the first stat1 timestamp is found that is >= stat2 timestamp,
			# the previous stat1 timestamp should be < stat2 timestamp.
			while ($stat1_timestamp_ms <= $stat2_timestamp_ms) {
				$prev_stat1_timestamp_ms = $stat1_timestamp_ms;
				$stat1_timestamp_ms = shift(@stat1_timestamps) || return;
			}
			my $stat1_value_base = get_value($add_from_ref, $prev_stat1_timestamp_ms);
			# if the stat2 timestamp is different from the first $stat1 timestamp, then adjust the value based on the difference of time and values
			my $stat2_prev_stat1_timestamp_diff_ms = ($stat2_timestamp_ms - $prev_stat1_timestamp_ms);
			my $value_adj = 0;
			if ($stat2_prev_stat1_timestamp_diff_ms != 0) {
				my $stat1_prev_stat1_timestamp_diff_ms = ($stat1_timestamp_ms - $prev_stat1_timestamp_ms);
				my $value_diff = get_value($add_from_ref, $stat1_timestamp_ms) - $stat1_value_base;
				$value_adj = $value_diff * $stat2_prev_stat1_timestamp_diff_ms/$stat1_prev_stat1_timestamp_diff_ms;
			}
			my $stat1_value_interp = $stat1_value_base + $value_adj;
			put_value($add_to_ref, $stat2_timestamp_ms,  get_value($add_to_ref,$stat2_timestamp_ms) + $stat1_value_interp);
			$count++;
		}
	}
}
sub value_exists {
	my $params = shift;
	my $key = $params;
	$params = shift;
	my $value = $params;
	$params = shift;
	my $array_ref = $params;
	my $i;
	for ($i=0; $i < scalar @{$array_ref}; $i++) {
		if ($$array_ref[$i]{$key} == $value) {
			return $i;
		}
	}
	return -1;
}

sub div_series {
	my $params = shift;
	my $div_from_ref = $params;
	$params = shift;
	my $divisor = $params;
	if ( $divisor > 0 ) {
	my $i;
		for ($i=0; $i < scalar @{$div_from_ref}; $i++) {
			$$div_from_ref[$i]{'value'} /= $divisor;
		}
	}
}

sub calc_aggregate_metrics {
	my $workload_ref = shift;
	# process any data in %workload{'throughput'|'latency'}, aggregating various per-client results
	my $metric_class;
	foreach $metric_class ('throughput', 'latency') {
		if ($$workload_ref{$metric_class}) {
			my $metric_type;
			foreach $metric_type (keys %{ $$workload_ref{$metric_class} }) {
				if (exists($$workload_ref{$metric_class}{$metric_type}[0]{get_label('skip_aggregate_label')})) {
					next;
				}

				my %agg_dataset; # a new dataset for aggregated results
				$agg_dataset{get_label('role_label')} = "aggregate";
				$agg_dataset{get_label('description_label')} = $$workload_ref{$metric_class}{$metric_type}[0]{get_label('description_label')};
				$agg_dataset{get_label('uid_label')} = $$workload_ref{$metric_class}{$metric_type}[0]{get_label('uid_label')};
				foreach my $label ( grep { $_ ne get_label('description_label') and
							   $_ ne get_label('value_label') and
							   $_ ne get_label('uid_label') and
							   $_ ne get_label('timeseries_label') and
							   $_ ne get_label('role_label') } (keys %{ $$workload_ref{$metric_class}{$metric_type}[0] } ) ) {
					$agg_dataset{$label} = "all";
				}
				# Ensure we have at least 1 good series
				my $num_ts = 0;
				my $num_metrics = 0;
				my $skip_metric = 0;
				for (my $i = 0; $i < scalar @{ $$workload_ref{$metric_class}{$metric_type} }; $i++) {
					if (exists($$workload_ref{$metric_class}{$metric_type}[$i]{get_label('skip_aggregate_label')})) {
						$skip_metric = 1
					}

					# A timeseries is considered valid if it has at least 2 timestamps
					if ((defined $$workload_ref{$metric_class}{$metric_type}[$i]{get_label('timeseries_label')}) and
					    (scalar get_timestamps(\@{ $$workload_ref{$metric_class}{$metric_type}[$i]{get_label('timeseries_label')}}) > 1)) {
						$num_ts++;
					}
					$num_metrics++;
				}
				if (($num_metrics == 0) || ($skip_metric == 1)) {
					next;
				}
				# In order to create an aggregate timeseries, we need at least 1 time series and all metrics must have timeseries data
				if ( $num_ts > 0 and $num_metrics == $num_ts ) {
					# The aggregate is initialized with the first series
					my @agg_series;
					my $first_series;
					foreach $first_series ( @{ $$workload_ref{$metric_class}{$metric_type}[0]{get_label('timeseries_label')} }  ) {
						my %sample = ( get_label('date_label') => int $$first_series{ get_label('date_label') }, get_label('value_label') => $$first_series{ get_label('value_label') } );
						push(@agg_series, \%sample);
					}

					# And if more series exist, they are added to the aggregate series
					if ( $num_ts > 0) {
						my $i;
						for ($i=1; $i < scalar @{ $$workload_ref{$metric_class}{$metric_type} }; $i++) {
							calc_sum_series(\@{ $$workload_ref{$metric_class}{$metric_type}[$i]{get_label('timeseries_label')} }, \@agg_series);
						}
						if ( $metric_class eq 'latency' ) {
							div_series(\@agg_series, $i);
						}
					}
					$agg_dataset{get_label('value_label')} = get_mean(\@agg_series);
					$agg_dataset{get_label('timeseries_label')} = \@agg_series;
				# If creating a new timeseries is not possible, the aggregate metric is constructed from the "value_label' from each metric instead.
				} else {
					my $i;
					my $value = 0;
					for ($i = 0; $i < scalar @{ $$workload_ref{$metric_class}{$metric_type} }; $i++) {
						$value += $$workload_ref{$metric_class}{$metric_type}[$i]{get_label('value_label')}
					}
					if ( $metric_class eq 'latency' ) {
						$value /= $i;
					}
					$agg_dataset{get_label('value_label')} = $value;
				}
				# The aggregate data should be the first in the array
				unshift(@{ $$workload_ref{$metric_class}{$metric_type} }, \%agg_dataset);
			}
		}
	}
}

sub calc_efficiency_metrics {
	my $params = shift;
	my $workload_ref = $params;

	my $resource_metric_name;
	if ($$workload_ref{'resource'} and $$workload_ref{'throughput'}) {
		foreach $resource_metric_name (keys %{ $$workload_ref{'resource'} }) {
			for (my $i = 0; $i < scalar @{ $$workload_ref{'resource'}{$resource_metric_name} }; $i++) { # cpu_busy[$i]
				foreach my $throughput_metric_name (keys %{ $$workload_ref{'throughput'} } ) { # Gb-sec, trans_sec
					for (my $j = 0; $j < scalar @{ $$workload_ref{'throughput'}{$throughput_metric_name} }; $j++) { # Gb_sec[$i], trans_sec[$i]
						if ( $$workload_ref{'throughput'}{$throughput_metric_name}[$j]{get_label('client_hostname_label')} eq $$workload_ref{'resource'}{$resource_metric_name}[$i]{get_label('hostname_label')} ) {
							my $eff_metric_name = $throughput_metric_name . "/" . $resource_metric_name;
							my %eff_dataset; # a new dataset for throughput/resource
							foreach my $label ('client_hostname_label', 'server_hostname_label', 'server_port_label') {
								$eff_dataset{get_label($label)} = $$workload_ref{'throughput'}{$throughput_metric_name}[$j]{get_label($label)};
							}
							foreach my $label ('hostname_label') {
								$eff_dataset{get_label($label)} = $$workload_ref{'resource'}{$resource_metric_name}[$i]{get_label($label)};
							}
							$eff_dataset{get_label('description_label')} = $$workload_ref{'throughput'}{$throughput_metric_name}[$j]{get_label('description_label')} . " divided-by " . $$workload_ref{'resource'}{$resource_metric_name}[$i]{get_label('description_label')};
							$eff_dataset{get_label('uid_label')} = $$workload_ref{'throughput'}{$throughput_metric_name}[$j]{get_label('uid_label')} . "/" . $$workload_ref{'resource'}{$resource_metric_name}[$i]{get_label('uid_label')};
							my @eff_samples;
							# And now we calculate a ratio
							calc_ratio_series(\@{ $$workload_ref{'throughput'}{$throughput_metric_name}[$j]{get_label('timeseries_label')} }, \@{ $$workload_ref{'resource'}{$resource_metric_name}[$i]{get_label('timeseries_label')} }, \@eff_samples);
							$eff_dataset{get_label('value_label')} = get_mean(\@eff_samples);
							$eff_dataset{get_label('timeseries_label')} = \@eff_samples;
							unshift(@{ $$workload_ref{'efficiency'}{$eff_metric_name} }, \%eff_dataset);
						}
					}
				}
			}
		}
	}
}

sub create_graph_hash {
	my $graph_ref = shift; # new data goes into this hash
	my $workload_ref = shift; # points to a %workload
	my $html_name = $$workload_ref{'parameters'}{'benchmark'}[0]{get_label('benchmark_name_label')};
	foreach my $metric_type ('throughput', 'latency', 'resource', 'efficiency') {
		if ($$workload_ref{$metric_type}) {
			foreach my $metric_name (keys %{ $$workload_ref{$metric_type} }) {
				for (my $i = 0; $i < scalar @{ $$workload_ref{$metric_type}{$metric_name} }; $i++) {
					my $series_name = get_uid($$workload_ref{$metric_type}{$metric_name}[$i]{get_label('uid_label')}, \%{ $$workload_ref{$metric_type}{$metric_name}[$i] });
					if (exists($$workload_ref{$metric_type}{$metric_name}[$i]{get_label('timeseries_label')})) {
						for (my $j = 0; $j < scalar @{ $$workload_ref{$metric_type}{$metric_name}[$i]{get_label('timeseries_label')} }; $j++ ) {
							my $timestamp_ms = $$workload_ref{$metric_type}{$metric_name}[$i]{get_label('timeseries_label')}[$j]{get_label('date_label')};
							if ($timestamp_ms) {
								my $value = $$workload_ref{$metric_type}{$metric_name}[$i]{get_label('timeseries_label')}[$j]{get_label('value_label')};
								my $graph_name = $metric_name;
								$graph_name =~ s/\//_per_/g;
								$$graph_ref{$html_name}{$graph_name}{$series_name}{$timestamp_ms} = $value;
							}
						}
					}
				}
			}
		}
	}
}

1;
