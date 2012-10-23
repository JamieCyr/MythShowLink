#!/usr/bin/perl -w

use Time::localtime;
use Getopt::Long;
use Time::Local;
use TVDB::API;
use Data::Dumper;
use JcUtils::Logger;
use JcUtils::FileDB;

our $basedir = "/var/MythShowLink/";
our $dataBase = $basedir . "mythShowIdMap";
our $NoEntryDB = $basedir . "NoIMDBEntryDB";
our $logFile = $basedir . "mythLinkLog";
our $destDir;
our $tvdbDb = $basedir . ".tvdb.db";
our $chanid;
our $starttime;
our $usage;
our $title;
our $subtitle;
our $rmsyms;
our $showid;
our $verbose;
our $apikey = "620DF64ADBA0979A"; #Needed for TVDB queries, you'll need to get your own :-)
our $language = "en";
our $fileformat;

# Load the cli options
GetOptions('chanid=s'		=> \$chanid,
	    'starttime=s'	=> \$starttime,
	    'usage|help|h'	=> \$usage,
	    'title=s'		=> \$title,
	    'subtitle=s'	=> \$subtitle,
	    'verbose'		=> \$verbose,
	    'rmsyms'		=> \$rmsyms,
	    'destdir=s'		=> \$destDir
	  );

if ($usage) {
  print <<EOF;
$0 usage:

All options are required and must be specified save for --rmsyms

options:

--chanid [channel id]
    Channel ID from MythTv %CHANID%

--starttime [start time]
    Program start time from MythTV %STARTTIME%

--title [title]
    Program Title, or Series name from MythTV %TITLE%

--subtitle [subtitle]
    Program Sub-Title, or episode name from MythTV %SUBTITLE%

--rmsyms
    Remove broken symbolic links as caused by this script; nothing else.
    
--destdir
	The destination directory, or link to, directory.

--help

EOF

exit;
}

#check dependencies
#check basedir
unless (-e $basedir) {
	mkdir $basedir, 0775 or die "Could not create $basedir which is needed for MythShowLink Files $! \n";
}

my $logger = JcUtils::Logger::new($logFile, 100000);

#Let's see if we only want to remove broken symbolic links
if (defined($rmsyms)) {
  print "Remove old symlinks \n";
  removeOldSymLinks();
  print "Done removing old symlinks \n";
  exit;
}

#Check if all arguments have been specified
if (!defined($chanid) || !defined($starttime) || !defined($title) || !defined($subtitle) || !defined($destDir)) {
  $logger->log("All arguments were not defined");
  die "All arguments must be defined";
}

#Does the destination directory exist, make it if we can
unless (-e $destDir) {
	unless (mkdir $destDir, 0775) {
		$logger->error->log("Could not create $destDir $!");
		die "Could not create $destDir $! \n";
	}
	$logger->warn->log("Had to create destination directory $destDir");
}

#Create year day for filename, should it be needed
$year = substr($starttime, 0, 4);
$month = substr($starttime, 4, 2);
$day = substr($starttime, 6, 2);
$showtime = timelocal(0,0,0,$day,$month,$year);
$YearDayNumber = localtime($showtime)->yday();

#before we create a TVDB object we need to make sure that the db can be created in the specified directory. 
unless (-e $tvdbDb){
	$logger->warn->log("The TVDB db: $tvdbDb needs to be created, because of a bug in TVDB::API this takes a long time");
	print "The TVDB db: $tvdbDb needs to be created, because of a bug in TVDB::API this takes a long time \n";
	my @tokens = split(/\//, $tvdbDb);
	pop(@tokens);
	my $dir;
	foreach $token (@tokens){
		$dir .= $token . "/";
	}
	unless (-w $dir){
		$logger->error->log("Can not write to $dir");
		die ("Can not write to $dir");
	}
}

#create the TVDB object.
our $tvdb = TVDB::API::new($apikey, $language, $tvdbDb);

#Create the DB object
our $db = JcUtils::FileDB::new($logger, $dataBase);
our $noentrydb = JcUtils::FileDB::new($logger, $NoEntryDB);

#Announce we're starting this process
$logger->log("Starting TVDB search for $title, $subtitle");

#Is the title in the local database
$showid = getShowId($title);
if ($showid > 1) {
  $logger->log("Found $showid for $title in local corrected DB");
  my $tmpTitle;
  $tmpTitle = $tvdb->getSeriesName($showid, 0);
  if (!defined($tmpTitle)) {
    $logger->log("TVDB did not return a valid title for $showid");
  }
  else {
  	$title = $tmpTitle;
  }
}

#See if the TVDB has the season episode numbers
@seasonEpisode = getSeasonEpisode($title, $subtitle);


if ($seasonEpisode[0] < 1 || $seasonEpisode[1] < 1) {
  $logger->log("Using year day to name $title, $subtitle");
  $name = $destDir . $title . "." . "S0" . "E" . $YearDayNumber . "." . $subtitle. ".mpg";
  if (-e $name) {
    $logger->log("$name already exists, making uuid");
    $uuid = makeUniqueFilename();
    $fileformat = "%T." . "S0" . "E".$YearDayNumber . $uuid . ".%S";
  }
  else {
    $fileformat = "%T." . "S0" . "E".$YearDayNumber . ".%S";
  }
}
else {
  $logger->log("Using info from TVDB to name $title, $subtitle");
  $fileformat = "%T." . "S".$seasonEpisode[0] . "E".$seasonEpisode[1] . ".%S";
}

if (defined($fileformat)) {
  $logger->log("File format for naming the file is: $fileformat");
  @args = ("perl", "/usr/local/bin/mythlink.pl", "--dest", $destDir, "--starttime", $starttime, "--chanid", $chanid, "--underscores", "--format", $fileformat);
  #system(@args);
  $logger->log("Completed naming the file");
}
else {
  $logger->log("There was an error creating the file format");
}

$logger->log("Finished TVDB search for $title, $subtitle");


#remove old sym links
#removeOldSymLinks();

$logger->closeLog();

exit;

#Get Show ID
#In some cases the show title returned form TVDB is slightly different
#than what MythTV has for the name.  We keep a user maintained file with those differences
#and must now check to see if this show has an entry.  If it does, we'll use the title as
#returned form the TVDB showid.
#Args: title
#Return: showid, if found
#Return: 0, if not found
sub getShowId {

  my $showName = $_[0];
  my $showid;
  #$showName =~ tr/A-Z/a-z/;
  
  my @results;
  my $entry = {};

  @results = $db->find('title', $showName);
  
  if (@results == 1 ) {
  	$entry = $db->fetch($results[0]);
  	$showid = $entry->{showId};
  	if ($showid == 0) {
  		$logger->warn->log("Entry $showName with db UUID $entry->{UUID} was 0, please update with correct showid");
  		return 0;
  	}
  	else {
  		return $showid;
  	}
  }
  
  if (@results > 1){
  	$logger->warn->log("More than one results returned for $showName");
  	return 0;
  }
  

}

#Make Unique Filename
#There is a posibility where two shows are recoreded back to back, the show is also not found in TVDB
#and would end up with the same name. This sub makes a unique number to append to the YearDayNumber.
#Return: uuid
sub makeUniqueFilename {

  $uuid = 0;
  $name = $destDir . $title . "." . "S0" . "E" . $YearDayNumber . $uuid . "." . $subtitle. ".mpg";
  while (-e $name) {
    $logger->log("$name already exists, will increment \n");
    $uuid++;
    $name = $destDir . $title . "." . "S0" . "E" . $YearDayNumber . $uuid . "." . $subtitle. ".mpg";
  }
    return $uuid;
}

#This is no longer used
#show name, season, episode
sub updateShowFile {

  my $backfile = $dataBase . ".bak";

  my $showName = $_[0];
  my $season = $_[1];
  my $episode = $_[2];

  unless (open(BACKFILE, ">$backfile")) {
    die "Could not open $backfile \n";
  }
  
  unless (open(SHOWFILE, "$dataBase")) {
      die "Could not open $dataBase \n";
    }

    while (<SHOWFILE>) {
	chomp;
	@fields = split(/:/, $_);
	
	if ($fields[0] eq $showName) {
	  my $entry = $showName . ":" . $season . ":" . $episode;
	  print BACKFILE $entry;
	}
	else {
	  print BACKFILE $_;
	}
    }

    close(BACKFILE);
    close(SHOWFILE);

    unlink($dataBase) || die "could not delete $dataBase \n";
    rename($backfile, $dataBase) || die "could not rename $backfile \n";

}

#Get Season and Episode
#Search the TVDB and return the season and episode numbers.
#It's a little tricky finding the season and episode combination from TVDB; but, it 
#can be done.
#Args: title, subtitle
#Return: array [season, episode]
sub getSeasonEpisode {

  my $episodename;
  my $title = $_[0];
  my $subtitle = $_[1];
  my $numepisodes;
  my $numseasons;
  
  if (!defined($subtitle)) {
  	$logger->warn->log("Subtitle is empty, no reason to look any further");
  	return (0, 0)
  }

  #turn subtitle to all lowercase
  $subtitle =~ tr/A-Z/a-z/;

  $numseasons = $tvdb->getMaxSeason($title, 0);
  #TODO: At times, TVDB can return the year (2010) on the getMaxSeason call,  Later in the code
  #getMaxEpisode will return undefined for the year and the loop will exit; however, this is
  #probably not the correct behavior as, I suppose, a particular season could have no episodes.
  if (!defined($numseasons)) {
  	my @results;
 	@results = $db->find('title', $title);
  	unless (@results >= 1 ) {
	  	$db->create({
	  		'title'	=> $title,
	  		'showId'	=> 0
	  	});
  	}
	$logger->warn->log("TVDB did not return any seasons for $title");
    $logger->warn->log("Possible name mismatch between MythTV and the TVDB, check it out and add showId enty to $dataBase");
	return(0, 0);
  }

  $logger->log("Looking for $title, $subtitle in all $numseasons seasons in TVDB");

  for ($i = 1; $i <= $numseasons; $i++) {
    $numepisodes = $tvdb->getMaxEpisode($title, $i, 0);
    if (!defined($numepisodes)) {
      $logger->log("TVDB return no episodes for $title");
      last;
    }

    for ($j = 1; $j <= $numepisodes; $j++) {
      $episodename = $tvdb->getEpisodeName($title, $i, $j, 0);
      if (!defined($episodename)) {
		$logger->log("TVDB return nothing for $title Season $i episode $j");
      }
      else {
		$episodename =~ tr/A-Z/a-z/;
		if ($episodename eq $subtitle) {
		  $logger->log("Found: $episodename in the TVDB");
		  return($i, $j);
		}
      }
    }
  }

  $logger->log("Could not find $title, $subtitle in the TVDB");
  
  #Let's make an entry in the DB so we can check TVDB at another time.
  $noentrydb->create({
  		'title'	=> $title,
  		'subTitle'	=> $subtitle,
  		'showId'	=> 0
  	});
  return (0, 0);

}

#Remove Old Symbolic Links
#This is a clean up routine that removes broken sybolic links as caused by the DVR deleting
#old shows that this scipts once made links to.
sub removeOldSymLinks {

  my $lcount = 0;
  my $zcount = 0;

  $logger->log("Removing Old Symbolic Links");

  #Not sure why we have to change dirs here, it seems readdir() does not return the full path name, or something.
  chdir($destDir) || die "Faild to change dir $!";

  opendir(VID, $destDir) || die "Failed to open directory: $!";
  while ($name = readdir(VID)) {
    if (-l $name) {
      $lcount++;
      $size = -s $name;
      if (!defined($size)) {
	unlink($name) || warn "Could not delete $name: $!\n";
	$logger->log("Removed Empty sym link: $name");
	$zcount++;
      }
    }
  }

  $logger->log("found $lcount links and removed $zcount \n");

  closedir(VID);
}
