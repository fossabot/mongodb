#!/usr/bin/env python
"""
Resmoke Test Suite Generator.

Analyze the evergreen history for tests run under the given task and create new evergreen tasks
to attempt to keep the task runtime under a specified amount.
"""

from __future__ import absolute_import

import argparse
import datetime
import logging
import math
import os
import re
import sys
from collections import defaultdict
from collections import namedtuple
from distutils.util import strtobool  # pylint: disable=no-name-in-module

import requests
import yaml

from shrub.config import Configuration
from shrub.command import CommandDefinition
from shrub.operations import CmdTimeoutUpdate
from shrub.task import TaskDependency
from shrub.variant import DisplayTaskDefinition
from shrub.variant import TaskSpec

# Get relative imports to work when the package is not installed on the PYTHONPATH.
if __name__ == "__main__" and __package__ is None:
    sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import buildscripts.client.evergreen as evergreen  # pylint: disable=wrong-import-position
import buildscripts.resmokelib.suitesconfig as suitesconfig  # pylint: disable=wrong-import-position
import buildscripts.util.read_config as read_config  # pylint: disable=wrong-import-position
import buildscripts.util.taskname as taskname  # pylint: disable=wrong-import-position
import buildscripts.util.testname as testname  # pylint: disable=wrong-import-position

LOGGER = logging.getLogger(__name__)

TEST_SUITE_DIR = os.path.join("buildscripts", "resmokeconfig", "suites")
CONFIG_DIR = "generated_resmoke_config"
MIN_TIMEOUT_SECONDS = 5 * 60

HEADER_TEMPLATE = """# DO NOT EDIT THIS FILE. All manual edits will be lost.
# This file was generated by {file} from
# {suite_file}.
"""

ConfigOptions = namedtuple("ConfigOptions", [
    "build_id",
    "depends_on",
    "fallback_num_sub_suites",
    "is_patch",
    "large_distro_name",
    "max_sub_suites",
    "project",
    "repeat_suites",
    "resmoke_args",
    "resmoke_jobs_max",
    "run_multiple_jobs",
    "suite",
    "target_resmoke_time",
    "task",
    "use_default_timeouts",
    "use_large_distro",
    "use_multiversion",
    "variant",
])


def enable_logging():
    """Enable verbose logging for execution."""

    logging.basicConfig(
        format="[%(asctime)s - %(name)s - %(levelname)s] %(message)s",
        level=logging.DEBUG,
        stream=sys.stdout,
    )


def split_if_exists(str_to_split):
    """Split the given string on "," if it is not None."""
    if str_to_split:
        return str_to_split.split(",")
    return None


def get_config_options(cmd_line_options, config_file):
    """
    Get the configuration to use for generated tests.

    Command line options override config file options.

    :param cmd_line_options: Command line options specified.
    :param config_file: config file to use.
    :return: ConfigOptions to use.
    """
    # pylint: disable=too-many-locals
    config_file_data = read_config.read_config_file(config_file)

    fallback_num_sub_suites = int(
        read_config.get_config_value("fallback_num_sub_suites", cmd_line_options, config_file_data,
                                     required=True))
    max_sub_suites = read_config.get_config_value("max_sub_suites", cmd_line_options,
                                                  config_file_data)
    project = read_config.get_config_value("project", cmd_line_options, config_file_data,
                                           required=True)
    resmoke_args = read_config.get_config_value("resmoke_args", cmd_line_options, config_file_data,
                                                default="")
    resmoke_jobs_max = read_config.get_config_value("resmoke_jobs_max", cmd_line_options,
                                                    config_file_data)
    target_resmoke_time = int(
        read_config.get_config_value("target_resmoke_time", cmd_line_options, config_file_data,
                                     default=60))
    run_multiple_jobs = read_config.get_config_value("run_multiple_jobs", cmd_line_options,
                                                     config_file_data, default="true")
    task = read_config.get_config_value("task", cmd_line_options, config_file_data, required=True)
    suite = read_config.get_config_value("suite", cmd_line_options, config_file_data, default=task)
    variant = read_config.get_config_value("build_variant", cmd_line_options, config_file_data,
                                           required=True)
    use_default_timeouts = read_config.get_config_value("use_default_timeouts", cmd_line_options,
                                                        config_file_data, default=False)
    use_large_distro = read_config.get_config_value("use_large_distro", cmd_line_options,
                                                    config_file_data, default=False)
    large_distro_name = read_config.get_config_value("large_distro_name", cmd_line_options,
                                                     config_file_data)
    use_multiversion = read_config.get_config_value("use_multiversion", cmd_line_options,
                                                    config_file_data)
    is_patch = read_config.get_config_value("is_patch", cmd_line_options, config_file_data)
    if is_patch:
        is_patch = strtobool(is_patch)
    depends_on = split_if_exists(
        read_config.get_config_value("depends_on", cmd_line_options, config_file_data))
    build_id = read_config.get_config_value("build_id", cmd_line_options, config_file_data)
    repeat_suites = int(
        read_config.get_config_value("resmoke_repeat_suites", cmd_line_options, config_file_data,
                                     default=1))

    return ConfigOptions(build_id, depends_on, fallback_num_sub_suites, is_patch, large_distro_name,
                         max_sub_suites, project, repeat_suites, resmoke_args, resmoke_jobs_max,
                         run_multiple_jobs, suite, target_resmoke_time, task, use_default_timeouts,
                         use_large_distro, use_multiversion, variant)


def divide_remaining_tests_among_suites(remaining_tests_runtimes, suites):
    """Divide the list of tests given among the suites given."""
    suite_idx = 0
    for test_file, runtime in remaining_tests_runtimes:
        current_suite = suites[suite_idx]
        current_suite.add_test(test_file, runtime)
        suite_idx += 1
        if suite_idx >= len(suites):
            suite_idx = 0


def divide_tests_into_suites(tests_runtimes, max_time_seconds, max_suites=None):
    """
    Divide the given tests into suites.

    Each suite should be able to execute in less than the max time specified.
    """
    suites = []
    current_suite = Suite()
    last_test_processed = len(tests_runtimes)
    LOGGER.debug("Determines suites for runtime: %ds", max_time_seconds)
    for idx, (test_file, runtime) in enumerate(tests_runtimes):
        LOGGER.debug("Adding test %s, runtime %d", test_file, runtime)
        if current_suite.get_runtime() + runtime > max_time_seconds:
            LOGGER.debug("Runtime(%d) + new test(%d) > max(%d)", current_suite.get_runtime(),
                         runtime, max_time_seconds)
            if current_suite.get_test_count() > 0:
                suites.append(current_suite)
                current_suite = Suite()
                if max_suites and len(suites) >= max_suites:
                    last_test_processed = idx
                    break

        current_suite.add_test(test_file, runtime)

    if current_suite.get_test_count() > 0:
        suites.append(current_suite)

    if max_suites and last_test_processed < len(tests_runtimes):
        # We must have hit the max suite limit, just randomly add the remaining tests to suites.
        divide_remaining_tests_among_suites(tests_runtimes[last_test_processed:], suites)

    return suites


def update_suite_config(suite_config, roots=None, excludes=None):
    """
    Update suite config based on the roots and excludes passed in.

    :param suite_config: suite_config to update.
    :param roots: new roots to run, or None if roots should not be updated.
    :param excludes: excludes to add, or None if excludes should not be include.
    :return: updated suite_config
    """
    if roots:
        suite_config["selector"]["roots"] = roots

    if excludes:
        # This must be a misc file, if the exclude_files section exists, extend it, otherwise,
        # create it.
        if "exclude_files" in suite_config["selector"] and \
                suite_config["selector"]["exclude_files"]:
            suite_config["selector"]["exclude_files"] += excludes
        else:
            suite_config["selector"]["exclude_files"] = excludes
    else:
        # if excludes was not specified this must not a misc file, so don"t exclude anything.
        if "exclude_files" in suite_config["selector"]:
            del suite_config["selector"]["exclude_files"]

    return suite_config


def generate_subsuite_file(source_suite_name, target_suite_name, roots=None, excludes=None):
    """
    Read and evaluate the yaml suite file.

    Override selector.roots and selector.excludes with the provided values. Write the results to
    target_suite_name.
    """
    source_file = os.path.join(TEST_SUITE_DIR, source_suite_name + ".yml")
    with open(source_file, "r") as fstream:
        suite_config = yaml.load(fstream)

    with open(os.path.join(CONFIG_DIR, target_suite_name + ".yml"), "w") as out:
        out.write(HEADER_TEMPLATE.format(file=__file__, suite_file=source_file))
        suite_config = update_suite_config(suite_config, roots, excludes)
        out.write(yaml.dump(suite_config, default_flow_style=False, Dumper=yaml.SafeDumper))


def render_suite(suites, suite_name):
    """Render the given suites into yml files that can be used by resmoke.py."""
    for idx, suite in enumerate(suites):
        suite.name = taskname.name_generated_task(suite_name, idx, len(suites))
        generate_subsuite_file(suite_name, suite.name, roots=suite.tests)


def render_misc_suite(test_list, suite_name):
    """Render a misc suite to run any tests that might be added to the directory."""
    subsuite_name = "{0}_{1}".format(suite_name, "misc")
    generate_subsuite_file(suite_name, subsuite_name, excludes=test_list)


def prepare_directory_for_suite(directory):
    """Ensure that dir exists."""
    if not os.path.exists(directory):
        os.makedirs(directory)


def calculate_timeout(avg_runtime, scaling_factor):
    """
    Determine how long a runtime to set based on average runtime and a scaling factor.

    :param avg_runtime: Average runtime of previous runs.
    :param scaling_factor: scaling factor for timeout.
    :return: timeout to use (in seconds).
    """

    def round_to_minute(runtime):
        """Round the given seconds up to the nearest minute."""
        distance_to_min = 60 - (runtime % 60)
        return int(math.ceil(runtime + distance_to_min))

    return max(MIN_TIMEOUT_SECONDS, round_to_minute(avg_runtime)) * scaling_factor


class EvergreenConfigGenerator(object):
    """Generate evergreen configurations."""

    def __init__(self, suites, options, evg_api):
        """Create new EvergreenConfigGenerator object."""
        self.suites = suites
        self.options = options
        self.evg_api = evg_api
        self.evg_config = Configuration()
        self.task_specs = []
        self.task_names = []
        self.build_tasks = None

    def _set_task_distro(self, task_spec):
        if self.options.use_large_distro and self.options.large_distro_name:
            task_spec.distro(self.options.large_distro_name)

    def _generate_resmoke_args(self, suite_file):
        resmoke_args = "--suite={0}.yml {1}".format(suite_file, self.options.resmoke_args)
        if self.options.repeat_suites and "repeat" not in resmoke_args:
            resmoke_args += " --repeat={0} ".format(self.options.repeat_suites)

        return resmoke_args

    def _get_run_tests_vars(self, suite_file):
        variables = {
            "resmoke_args": self._generate_resmoke_args(suite_file),
            "run_multiple_jobs": self.options.run_multiple_jobs,
            "task": self.options.task,
        }

        if self.options.resmoke_jobs_max:
            variables["resmoke_jobs_max"] = self.options.resmoke_jobs_max

        if self.options.use_multiversion:
            variables["task_path_suffix"] = self.options.use_multiversion

        return variables

    def _add_timeout_command(self, commands, max_test_runtime, expected_suite_runtime):
        """
        Add an evergreen command to override the default timeouts to the list of commands.

        :param commands: List of commands to add timeout command to.
        :param max_test_runtime: Maximum runtime of any test in the sub-suite.
        :param expected_suite_runtime: Expected runtime of the entire sub-suite.
        """
        repeat_factor = self.options.repeat_suites
        if max_test_runtime or expected_suite_runtime:
            cmd_timeout = CmdTimeoutUpdate()
            if max_test_runtime:
                timeout = calculate_timeout(max_test_runtime, 3) * repeat_factor
                LOGGER.debug("Setting timeout to: %d (max=%d, repeat=%d)", timeout,
                             max_test_runtime, repeat_factor)
                cmd_timeout.timeout(timeout)
            if expected_suite_runtime:
                exec_timeout = calculate_timeout(expected_suite_runtime, 3) * repeat_factor
                LOGGER.debug("Setting exec_timeout to: %d (runtime=%d, repeat=%d)", exec_timeout,
                             expected_suite_runtime, repeat_factor)
                cmd_timeout.exec_timeout(exec_timeout)
            commands.append(cmd_timeout.validate().resolve())

    @staticmethod
    def _is_task_dependency(task, possible_dependency):
        return re.match("{0}_(\\d|misc)".format(task), possible_dependency)

    def _get_tasks_for_depends_on(self, dependent_task):
        return [
            str(task["display_name"]) for task in self.build_tasks
            if self._is_task_dependency(dependent_task, str(task["display_name"]))
        ]

    def _add_dependencies(self, task):
        task.dependency(TaskDependency("compile"))
        if not self.options.is_patch:
            # Don"t worry about task dependencies in patch builds, only mainline.
            if self.options.depends_on:
                for dep in self.options.depends_on:
                    depends_on_tasks = self._get_tasks_for_depends_on(dep)
                    for dependency in depends_on_tasks:
                        task.dependency(TaskDependency(dependency))

        return task

    def _generate_task(self, sub_suite_name, sub_task_name, max_test_runtime=None,
                       expected_suite_runtime=None):
        """Generate evergreen config for a resmoke task."""
        LOGGER.debug("Generating task for: %s", sub_suite_name)
        spec = TaskSpec(sub_task_name)
        self._set_task_distro(spec)
        self.task_specs.append(spec)

        self.task_names.append(sub_task_name)
        task = self.evg_config.task(sub_task_name)

        target_suite_file = os.path.join(CONFIG_DIR, sub_suite_name)
        run_tests_vars = self._get_run_tests_vars(target_suite_file)

        commands = []
        if not self.options.use_default_timeouts:
            self._add_timeout_command(commands, max_test_runtime, expected_suite_runtime)
        commands.append(CommandDefinition().function("do setup"))
        if self.options.use_multiversion:
            commands.append(CommandDefinition().function("do multiversion setup"))
        commands.append(CommandDefinition().function("run generated tests").vars(run_tests_vars))

        self._add_dependencies(task).commands(commands)

    def _generate_all_tasks(self):
        for idx, suite in enumerate(self.suites):
            sub_task_name = taskname.name_generated_task(self.options.task, idx, len(self.suites),
                                                         self.options.variant)
            max_runtime = None
            total_runtime = None
            if suite.should_overwrite_timeout():
                max_runtime = suite.max_runtime
                total_runtime = suite.get_runtime()
            self._generate_task(suite.name, sub_task_name, max_runtime, total_runtime)

        # Add the misc suite
        misc_suite_name = "{0}_misc".format(self.options.suite)
        self._generate_task(misc_suite_name, "{0}_misc_{1}".format(self.options.task,
                                                                   self.options.variant))

    def _generate_display_task(self):
        dt = DisplayTaskDefinition(self.options.task)\
            .execution_tasks(self.task_names) \
            .execution_task("{0}_gen".format(self.options.task))
        return dt

    def _generate_variant(self):
        self._generate_all_tasks()

        self.evg_config.variant(self.options.variant)\
            .tasks(self.task_specs)\
            .display_task(self._generate_display_task())

    def generate_config(self):
        """Generate evergreen configuration."""
        self.build_tasks = self.evg_api.tasks_by_build_id(self.options.build_id)
        self._generate_variant()
        return self.evg_config


def normalize_test_name(test_name):
    """Normalize test names that may have been run on windows or unix."""
    return test_name.replace("\\", "/")


class TestStats(object):
    """Represent the test statistics for the task that is being analyzed."""

    def __init__(self, evg_test_stats_results):
        """Initialize the TestStats with raw results from the Evergreen API."""
        # Mapping from test_file to {"num_run": X, "duration": Y} for tests
        self._runtime_by_test = defaultdict(dict)
        # Mapping from test_name to {"num_run": X, "duration": Y} for hooks
        self._hook_runtime_by_test = defaultdict(dict)

        for doc in evg_test_stats_results:
            self._add_stats(doc)

    def _add_stats(self, test_stats):
        """Add the statistics found in a document returned by the Evergreen test_stats/ endpoint."""
        test_file = testname.normalize_test_file(test_stats["test_file"])
        duration = test_stats["avg_duration_pass"]
        num_run = test_stats["num_pass"]
        is_hook = testname.is_resmoke_hook(test_file)
        if is_hook:
            self._add_test_hook_stats(test_file, duration, num_run)
        else:
            self._add_test_stats(test_file, duration, num_run)

    def _add_test_stats(self, test_file, duration, num_run):
        """Add the statistics for a test."""
        self._add_runtime_info(self._runtime_by_test, test_file, duration, num_run)

    def _add_test_hook_stats(self, test_file, duration, num_run):
        """Add the statistics for a hook."""
        test_name = testname.split_test_hook_name(test_file)[0]
        self._add_runtime_info(self._hook_runtime_by_test, test_name, duration, num_run)

    @staticmethod
    def _add_runtime_info(runtime_dict, test_name, duration, num_run):
        runtime_info = runtime_dict[test_name]
        if not runtime_info:
            runtime_info["duration"] = duration
            runtime_info["num_run"] = num_run
        else:
            runtime_info["duration"] = TestStats._average(
                runtime_info["duration"], runtime_info["num_run"], duration, num_run)
            runtime_info["num_run"] += num_run

    @staticmethod
    def _average(value_a, num_a, value_b, num_b):
        """Compute a weighted average of 2 values with associated numbers."""
        return float(value_a * num_a + value_b * num_b) / (num_a + num_b)

    def get_tests_runtimes(self):
        """Return the list of (test_file, runtime_in_secs) tuples ordered by decreasing runtime."""
        tests = []
        for test_file, runtime_info in self._runtime_by_test.items():
            duration = runtime_info["duration"]
            test_name = testname.get_short_name_from_test_file(test_file)
            hook_runtime_info = self._hook_runtime_by_test[test_name]
            if hook_runtime_info:
                duration += hook_runtime_info["duration"]
            tests.append((normalize_test_name(test_file), duration))
        return sorted(tests, key=lambda x: x[1], reverse=True)


class Suite(object):
    """A suite of tests that can be run by evergreen."""

    def __init__(self):
        """Initialize the object."""
        self.tests = []
        self.total_runtime = 0
        self.max_runtime = 0
        self.tests_with_runtime_info = 0

    def add_test(self, test_file, runtime):
        """Add the given test to this suite."""

        self.tests.append(test_file)
        self.total_runtime += runtime

        if runtime != 0:
            self.tests_with_runtime_info += 1

        if runtime > self.max_runtime:
            self.max_runtime = runtime

    def should_overwrite_timeout(self):
        """
        Whether the timeout for this suite should be overwritten.

        We should only overwrite the timeout if we have runtime info for all tests.
        """
        return len(self.tests) == self.tests_with_runtime_info

    def get_runtime(self):
        """Get the current average runtime of all the tests currently in this suite."""

        return self.total_runtime

    def get_test_count(self):
        """Get the number of tests currently in this suite."""

        return len(self.tests)


class Main(object):
    """Orchestrate the execution of generate_resmoke_suites."""

    def __init__(self, evergreen_api):
        """Initialize the object."""
        self.evergreen_api = evergreen_api
        self.options = None
        self.config_options = None
        self.test_list = []

    def parse_commandline(self):
        """Parse the command line options and return the parsed data."""
        parser = argparse.ArgumentParser(description=self.main.__doc__)

        parser.add_argument("--expansion-file", dest="expansion_file", type=str,
                            help="Location of expansions file generated by evergreen.")
        parser.add_argument("--analysis-duration", dest="duration_days", default=14,
                            help="Number of days to analyze.", type=int)
        parser.add_argument("--execution-time", dest="target_resmoke_time", type=int,
                            help="Target execution time (in minutes).")
        parser.add_argument("--max-sub-suites", dest="max_sub_suites", type=int,
                            help="Max number of suites to divide into.")
        parser.add_argument("--fallback-num-sub-suites", dest="fallback_num_sub_suites", type=int,
                            help="The number of suites to divide into if the Evergreen test "
                            "statistics are not available.")
        parser.add_argument("--project", dest="project", help="The Evergreen project to analyse.")
        parser.add_argument("--resmoke-args", dest="resmoke_args",
                            help="Arguments to pass to resmoke calls.")
        parser.add_argument("--resmoke-jobs_max", dest="resmoke_jobs_max",
                            help="Number of resmoke jobs to invoke.")
        parser.add_argument("--suite", dest="suite",
                            help="Name of suite being split(defaults to task_name)")
        parser.add_argument("--run-multiple-jobs", dest="run_multiple_jobs",
                            help="Should resmoke run multiple jobs")
        parser.add_argument("--task-name", dest="task", help="Name of task to split.")
        parser.add_argument("--variant", dest="build_variant",
                            help="Build variant being run against.")
        parser.add_argument("--use-large-distro", dest="use_large_distro",
                            help="Should subtasks use large distros.")
        parser.add_argument("--large-distro-name", dest="large_distro_name",
                            help="Name of large distro.")
        parser.add_argument("--use-default_timeouts", dest="use_default_timeouts",
                            help="When specified, do not override timeouts based on test history.")
        parser.add_argument("--use-multiversion", dest="use_multiversion",
                            help="Task path suffix for multiversion generated tasks.")
        parser.add_argument("--is-patch", dest="is_patch", help="Is this part of a patch build.")
        parser.add_argument("--depends-on", dest="depends_on",
                            help="Generate depends on for these tasks.")
        parser.add_argument("--repeat-suites", dest="resmoke_repeat_suites",
                            help="Repeat each suite the specified number of times.")
        parser.add_argument("--verbose", dest="verbose", action="store_true", default=False,
                            help="Enable verbose logging.")

        options = parser.parse_args()

        self.config_options = get_config_options(options, options.expansion_file)
        return options

    def calculate_suites(self, start_date, end_date):
        """Divide tests into suites based on statistics for the provided period."""
        try:
            evg_stats = self.get_evg_stats(self.config_options.project, start_date, end_date,
                                           self.config_options.task, self.config_options.variant)
            if not evg_stats:
                # This is probably a new suite, since there is no test history, just use the
                # fallback values.
                return self.calculate_fallback_suites()
            target_execution_time_secs = self.config_options.target_resmoke_time * 60
            return self.calculate_suites_from_evg_stats(evg_stats, target_execution_time_secs)
        except requests.HTTPError as err:
            if err.response.status_code == requests.codes.SERVICE_UNAVAILABLE:
                # Evergreen may return a 503 when the service is degraded.
                # We fall back to splitting the tests into a fixed number of suites.
                LOGGER.warning("Received 503 from Evergreen, "
                               "dividing the tests evenly among suites")
                return self.calculate_fallback_suites()
            else:
                raise

    def get_evg_stats(self, project, start_date, end_date, task, variant):
        """Collect test execution statistics data from Evergreen."""
        # pylint: disable=too-many-arguments

        days = (end_date - start_date).days
        return self.evergreen_api.test_stats(project, after_date=start_date.strftime("%Y-%m-%d"),
                                             before_date=end_date.strftime("%Y-%m-%d"),
                                             tasks=[task], variants=[variant], group_by="test",
                                             group_num_days=days)

    def calculate_suites_from_evg_stats(self, data, execution_time_secs):
        """Divide tests into suites that can be run in less than the specified execution time."""
        test_stats = TestStats(data)
        tests_runtimes = self.filter_existing_tests(test_stats.get_tests_runtimes())
        if not tests_runtimes:
            return self.calculate_fallback_suites()
        self.test_list = [info[0] for info in tests_runtimes]
        return divide_tests_into_suites(tests_runtimes, execution_time_secs,
                                        self.options.max_sub_suites)

    def filter_existing_tests(self, tests_runtimes):
        """Filter out tests that do not exist in the filesystem."""
        all_tests = [normalize_test_name(test) for test in self.list_tests()]
        return [info for info in tests_runtimes if os.path.exists(info[0]) and info[0] in all_tests]

    def calculate_fallback_suites(self):
        """Divide tests into a fixed number of suites."""
        num_suites = self.config_options.fallback_num_sub_suites
        self.test_list = self.list_tests()
        suites = [Suite() for _ in range(num_suites)]
        for idx, test_file in enumerate(self.test_list):
            suites[idx % num_suites].add_test(test_file, 0)
        return suites

    def list_tests(self):
        """List the test files that are part of the suite being split."""
        return suitesconfig.get_suite(self.config_options.suite).tests

    def write_evergreen_configuration(self, suites, task):
        """Generate the evergreen configuration for the new suite and write it to disk."""
        evg_config_gen = EvergreenConfigGenerator(suites, self.config_options, self.evergreen_api)
        evg_config = evg_config_gen.generate_config()

        with open(os.path.join(CONFIG_DIR, task + ".json"), "w") as file_handle:
            file_handle.write(evg_config.to_json())

    def main(self):
        """Generate resmoke suites that run within a specified target execution time."""

        options = self.parse_commandline()
        self.options = options

        if options.verbose:
            enable_logging()

        LOGGER.debug("Starting execution for options %s", options)
        LOGGER.debug("config options %s", self.config_options)
        end_date = datetime.datetime.utcnow().replace(microsecond=0)
        start_date = end_date - datetime.timedelta(days=options.duration_days)

        prepare_directory_for_suite(CONFIG_DIR)

        suites = self.calculate_suites(start_date, end_date)

        LOGGER.debug("Creating %d suites for %s", len(suites), self.config_options.task)

        render_suite(suites, self.config_options.suite)
        render_misc_suite(self.test_list, self.config_options.suite)

        self.write_evergreen_configuration(suites, self.config_options.task)


if __name__ == "__main__":
    Main(evergreen.get_evergreen_apiv2()).main()
