<?php

/**
 * This script is intended for the command-line, and receives two arguments:
 *  - the path to the readme.txt file to be parsed
 *  - the path to the changelog.txt file to be generated
 *
 * It will parse the readme.txt file and generate a changelog.txt file
 *
 * Example usage: `php parse-readme-changelog.php readme.txt changelog.txt`
 */

if (!isset($argv[1]) || !isset($argv[2])) {
    die("Usage: php parse-readme-changelog.php readme.txt changelog.txt ");
}

$readme = file_get_contents($argv[1]);
$changelog = fopen($argv[2], 'w');

// Clear the changelog.txt file
ftruncate($changelog, 0);

// Grab the first line of the file
$firstLine = strtok($readme, "\n");

// Parse the plugin name from the first line in the format of "=== Plugin Name ==="
$pluginName = preg_replace('/^=== (.+) ===$/', '$1', $firstLine);
fwrite($changelog, "*** $pluginName changelog ***\n\n");

// Parse the readme.txt file
$readme = explode('== Changelog ==', $readme);

if (count($readme) < 2) {
    die();
}

// normalize line endings
$changeLogSection = preg_replace('~\R~u', "\n", $readme[1]);

$firstLine = true;
$line = strtok($changeLogSection, "\n");

while ($line !== false) {
    if ( preg_match('= (\d+\.\d+\.\d+): ([a-zA-Z]+ \d{1,2}\w{2}, \d{4}) =', $line, $matches) ) {
        $version = $matches[1];
        $date = new DateTime($matches[2]);

        $line = "{$date->format('Y-m-d')} - version $version";

        if ($firstLine) {
            $firstLine = false;
        } else {
            // Add a blank line between versions
            fwrite($changelog, "\n");
        }

    } else {
        // remove the leading asterisk
        $line = '-' . substr($line, 1);
    }

    // Write the line to the changelog.txt file
    fwrite($changelog, $line . "\n");

    $line = strtok("\n");
}
