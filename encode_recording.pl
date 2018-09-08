#!/usr/bin/perl

# This script is called by MythTV after a recording finishes so that I can
# archive it to my NAS.
#
# It reads the databsae information from the mythtv user's home directory,
# gathers metadata, finds the recording on disk, calculates the output
# filename and then finally calls handbrake encode.
#
# A log file is generated for debugging/historical purposes (sample at the end
# of the file).

use Getopt::Long;
use Data::Dumper;
use JSON;
use XML::Simple;
use Data::Dumper;
use DBI;

our( @startArguments, $infile, $title, $subtitle );
@startArguments = @ARGV;
GetOptions( "infile=s"      => \$infile,
            "title=s"       => \$title,
            "subtitle=s"    => \$subtitle,
            "chanId=i"      => \$chanId,
            "starttime=s"   => \$startTime
        );

# local variables to track directories in use
my $tempDir = "/var/mythrecord";
my $targetDir = "/mnt/plex";
my $logfile = "/mnt/nas/hbclilogs/logFile.log";
my $HandBrakeCLI = "/usr/bin/HandBrakeCLI";

# fully qualified commands
my $mv = "/bin/mv";
my $mkdir = "/bin/mkdir";

open (LOG, ">> $logfile");

# Find the filename on disk since all we get is the filename and not the
# whole directory. I only have two possible directories it would be in
# so they are hardcoded here. 
# A future opportunity would be to make that read from all the storage
# directories on MythTV but for home use when these never change, this will do.
sub findEpisodeOnDisk {
    local( $feodInfile );
    $feodInfile = $_[0];
    my @dirArray = ("/var/mythrecord/", "/mnt/nas/recordings/");
    my $fullPath = "";

    foreach my $dir ( @dirArray ) {
        $fullPath = $dir . $feodInfile;
        print LOG "Looking for file with path: $fullPath\n";

        if( -f $fullPath ) {
            print LOG "Found it!\n";
            return $fullPath;
        }
    }

    die "No valid file path found!"
}

# a list of arguments for handbrake that maximises quality while minimizing time to encode
my $HBcliArguments = " --no-opencl -t 1 --angle 1 -c 1 -f mp4 --encoder x264 -q 20 -2 --loose-anamorphic --detelecine --deinterlace \"slow\" --x264-profile=high --h264-level=\"4.1\" --verbose=1 --no-dvdnav -v --mixdown 6ch";

print LOG "--------------------------------------------------------------------\n";
print LOG scalar(localtime(time));
print LOG "\n";

my $infileFullPath = findEpisodeOnDisk( $infile );
my $outputFile = "\"$targetDir/$title - $subtitle.mp4\"";
my $outputTempFile = "\"$tempDir/$title" . " - " . "$subtitle" . ".mp4\"";

# map channel ID and start time to episode entry in the database
print LOG "Looking for S/E number, attepting to use directory output\n";

# read password from file
# my $xml = new XML::Simple;
my $data = XMLin("/home/mythtv/.mythtv/config.xml");

# gather creds
my $username = $data->{Database}->{UserName};
print LOG "Username: " . $username . "\n";
my $password = $data->{Database}->{Password};
# debugging print $LOG "Password: " . $password . "\n";
my $dbServer = $data->{Database}->{Host};
print LOG "DB Server: " . $dbServer . "\n";
my $dbPort = $data->{Database}->{Port};
print LOG "DB Port: " . $dbPort . "\n";
my $dbDatabaseName = $data->{Database}->{DatabaseName};
print LOG "DB Database name: " . $dbDatabaseName . "\n";

# setup/make database connection
my $dbh = DBI->connect( "DBI:mysql:$dbDatabaseName:$dbServer:$dbPort", $username, $password ) or die "Unable to connect: $DBI::errstr\n";

# run query
my $sth = $dbh->prepare( "select * from recorded where chanid=$chanId and starttime=$startTime" );
$sth->execute();
my $result;

# dump the entire database row for logging purposes
while (my $ref = $sth->fetchrow_hashref() ) {
    print LOG Dumper( $ref );
    $result = $ref;
}

#save local variables from the database record
my $showTitle = $result->{'title'};
my $episodeTitle = $result->{'subtitle'};
my $infileName = $result->{'basename'};
my $season = $result->{'season'};
my $episode = $result->{'episode'};
my $category = $result->{'category'};
my $storageGroup = $result->{'storagegroup'};
my $startDate = $result->{'starttime'};

# assuming we have a TV show, the $season and $episode will be populated.
# use that to determine the output filename that plex will like
if( $season > 0 && $episode > 0 ) {
    print LOG "Found S/E number, using that for output.\n";
    $season = $season < 10 ? "0" . $season : $season;
    $episode = $episode < 10 ? "0" . $episode : $episode;

    print LOG "Season is: " . $season . "\n";
    print LOG "Episode is: " . $episode . "\n";

    my $outFileName = "$title - S" . $season . "E" . $episode ." - $subtitle.mp4";
    print LOG "Episode file only name: $outFileName\n";

    $outputTempFile = "\"$tempDir/$outFileName\"";
    my $fullOutputPath = "\"$targetDir/TV Shows/$title/Season $season/\"";
    print LOG "Folder tv show episode path is: " . $fullOutputPath . "\n";
    system( $mkdir . " -p " . $fullOutputPath );
    $outputFile = "\"$targetDir/TV Shows/$title/Season $season/$outFileName\"";
    print LOG "Full TV Show path is: $outputFile\n";
}

# during the olympics, I put this in here so I can just copy the recording
# in to the NAS directory and title it with the subtitle, which listed the
# sports involved
if( $title eq "2018 Winter Olympics" ) {
    print LOG "found olympics title" . "\n";

    # get the day from the recording start date
    my @dateParsed = split( /-| /, $startDate );
    $date = $dateParsed[2];

    $outputTempFile = "\"/mnt/plex/Home Movies/Winter Olympics/Feb-$date $subtitle.mp4\"";

    print LOG "In file full path: " . $infileFullPath . "\n";

    #example: $outputFile /mnt/plex/Home Movies/Winter Olympics/Feb-18 Snowboarding.mp4
    print LOG "Final output location: " . $outputFile . "\n";

    system ( "cp " . $infileFullPath . " /mnt/nas/tmp" );
    system ( "cp " . $infileFullPath . " " . "\"/mnt/plex/Home Movies/Winter Olympics/Feb-$date $subtitle.ts\"" );
} else {
    # if we don't have a 2018 Olympic title, call the regular handbrake encoding,
    # which will write it to a temp file and then move it to the output directory
    print LOG "In file full path: " . $infileFullPath . "\n";
    print LOG "Output temp file: " . $outputTempFile . "\n";
    print LOG "Final output location: " . $outputFile . "\n";

    print LOG $HandBrakeCLI . " -i " . $infileFullPath . " -o " . "$outputTempFile" . " " . $HBcliArguments . "\n";
    system( $HandBrakeCLI . " -i " . $infileFullPath . " -o " . "$outputTempFile" . " " . $HBcliArguments );

    # just in case there's an existing file there, use --backup-t which won't
    # clobber existing files
    print LOG $mv . " --backup=t " . $outputTempFile . " " .  $outputFile . "\n";
    system( $mv . " --backup=t " . $outputTempFile . " " .  $outputFile );
}

print LOG "Finsihed encoding\n";

print LOG scalar(localtime(time));
print LOG "\n";

print LOG "--------------------------------------------------------------------\n";
close (LOG);


# Sample log file output
# --------------------------------------------------------------------
# Tue Sep  4 00:10:47 2018
# Looking for file with path: /var/mythrecord/1804_20180904015900.ts
# Found it!
# Looking for S/E number, attepting to use directory output
# Username: mythtv
# DB Server: mythtv.ajlhl.io
# DB Port: 3306
# DB Database name: mythconverg
# $VAR1 = {
#           'season' => 6,
#           'description' => 'Holmes and Watson race to locate a missing woman; Holmes\' friend becomes the prime suspect in the woman\'s disappearance.',
#           'category' => 'Crime drama',
#           'programid' => 'EP015686040141',
#           'profile' => 'Default',
#           'basename' => '1804_20180904015900.ts',
#           'previouslyshown' => 0,
#           'stars' => '0',
#           'filesize' => 6883890720,
#           'chanid' => 1804,
#           'recordedid' => 3293,
#           'timestretch' => '1',
#           'findid' => 0,
#           'transcoded' => 0,
#           'watched' => 0,
#           'preserve' => 0,
#           'deletepending' => 0,
#           'starttime' => '2018-09-04 01:59:00',
#           'inputname' => 'Ceton-1',
#           'inetref' => 'ttvdb.py_255316',
#           'lastmodified' => '2018-09-04 00:09:46',
#           'editing' => 0,
#           'title' => 'Elementary',
#           'seriesid' => 'EP01568604',
#           'duplicate' => 1,
#           'bookmark' => 0,
#           'recpriority' => 0,
#           'recordid' => 556,
#           'cutlist' => 0,
#           'progend' => '2018-09-04 03:00:00',
#           'progstart' => '2018-09-04 02:00:00',
#           'bookmarkupdate' => '0000-00-00 00:00:00',
#           'storagegroup' => 'Default',
#           'subtitle' => 'The Geek Interpreter',
#           'recgroup' => 'Default',
#           'autoexpire' => 1,
#           'recgroupid' => 1,
#           'transcoder' => 0,
#           'endtime' => '2018-09-04 03:01:00',
#           'playgroup' => 'Default',
#           'episode' => 19,
#           'originalairdate' => '2018-09-03',
#           'hostname' => 'mythtv',
#           'commflagged' => 0
#         };
# Found S/E number, using that for output.
# Season is: 06
# Episode is: 19
# Episode file only name: Elementary - S06E19 - The Geek Interpreter.mp4
# Folder tv show episode path is: "/mnt/plex/TV Shows/Elementary/Season 06/"
# Full TV Show path is: "/mnt/plex/TV Shows/Elementary/Season 06/Elementary - S06E19 - The Geek Interpreter.mp4"
# In file full path: /var/mythrecord/1804_20180904015900.ts
# Output temp file: "/var/mythrecord/Elementary - S06E19 - The Geek Interpreter.mp4"
# Final output location: "/mnt/plex/TV Shows/Elementary/Season 06/Elementary - S06E19 - The Geek Interpreter.mp4"
# /usr/bin/HandBrakeCLI -i /var/mythrecord/1804_20180904015900.ts -o "/var/mythrecord/Elementary - S06E19 - The Geek Interpreter.mp4"  --no-opencl -t 1 --angle 1 -c 1 -f mp4 --encoder x264 -q 20 -2 --loose-anamorphic --detelecine --deinterlace "slow" --x264-profile=high --h264-level="4.1" --verbose=1 --no-dvdnav -v --mixdown 6ch
# /bin/mv --backup=t "/var/mythrecord/Elementary - S06E19 - The Geek Interpreter.mp4" "/mnt/plex/TV Shows/Elementary/Season 06/Elementary - S06E19 - The Geek Interpreter.mp4"
# Finsihed encoding
# Tue Sep  4 01:55:46 2018
# --------------------------------------------------------------------
