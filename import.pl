#!/usr/bin/perl

use strict;
use XML::Simple;
use lib qw(/var/www/html);
use AppD_Import;
use Getopt::Long;
use File::Basename qw(dirname);
use HTTP::Cookies;
use XMLRPC::Lite;
use VMware::ImportExternal;
use Data::Dumper;
use Bugzilla;
use Bugzilla::Util qw(lsearch);
use HTML::Strip;

my $options = {};

my $really_do=1;

my $Bugzilla_login;
my $Bugzilla_password;
my $Bugzilla_remember;
my $help;

GetOptions("data_file=s"    => \$options->{'data_file'},
           'uri=s'          => \$options->{'uri'},
           'login:s'        => \$Bugzilla_login,
           'password=s'     => \$Bugzilla_password,
           'rememberlogin!' => \$Bugzilla_remember,
           'help|h'         => \$help,

);
if ( $help ) {
    &help();
    exit;
}
my $log_dir = '/var/www/html/log/';
my $log_filename = $log_dir . 'AppD_Import.log';  ##log file name
if ( -f $log_filename ){
    unlink $log_filename;
}
# First set up the nescessary XMLRPC items that will be needed
# to use the web services after all the data is parsed.

# Open our cookie jar so we only have to login once.
my $cookie_jar =
    new HTTP::Cookies('file' => File::Spec->catdir(dirname($0), 'cookies.txt'),
                      'autosave' => 1);
die "--uri must be specified - you probably want something like:\n --uri=https://gargv-bz3.eng.vmware.com/xmlrpc.cgi\n" unless $options->{'uri'};

my $proxy = XMLRPC::Lite->proxy($options->{'uri'},
                                'cookie_jar' => $cookie_jar);

if (defined($Bugzilla_login)) {
    if ($Bugzilla_login ne '') {
        # Log in.
        my $soapresult = $proxy->call('User.login',
                                   { login => $Bugzilla_login,
                                     password => $Bugzilla_password,
                                     remember => $Bugzilla_remember } );
        _die_on_fault($soapresult);
        print "Login successful.\n";
    }
    else {
        # Log out.
        my $soapresult = $proxy->call('User.logout');
        _die_on_fault($soapresult);
        print "Logout successful.\n";
    }
}
my $dbh = Bugzilla->dbh;
my ($timestamp) = $dbh->selectrow_array("SELECT NOW()");

#my $product_name = 'Application Director - Legacy';
my $product_name ='Application Director 6.0 (sandbox)';

my $imported_already = $dbh->selectcol_arrayref("select external_id from imported_bug_id_map join products on products.id=imported_bug_id_map.product_id and name = '$product_name';");
print "imported_already\n";
my $bugzilla_col = {
   'priority' => 'severity',
   'summary' => 'summary',
   'status' => 'status',
   'resolution' => 'resolution',
   'description' => 'description',
   'component' => 'category',
   'reporter' => 'reporter',
   'assignee' => 'assigned_to',
   'created' => 'creation_ts',
   'updated' => 'delta_ts',
   'environment' => 'host_op_sys',
   'version' => 'found_in_version',
   'fixVersion' => 'fix_by',
   'type' => 'bug_type',
   'due' =>'cf_eta',
   'comments' => 'comment',
};
my $ref = XMLin($options->{'data_file'}, KeyAttr => ['rss']);
warn "Done reading XML\n";

my $bug_data;
my $column_data;
my $converted_data;
my $user_data;
foreach my $item (@{$ref->{'channel'}->{'item'}}) {
    my $external_id='';
    my $defect_data;
    my $import_comment = '';
    my @additional_fields = ();
    $defect_data->{'cf_reported_by'} = 'QA';
    $defect_data->{'guest_op_sys'} = '';
    $defect_data->{'product'} = $product_name;
    $defect_data->{'product_id'}=$product_name;

    foreach my $field (keys %$item) {
        if ($field eq 'key' ) {
            $external_id = $item->{'key'}->{'content'};
            $external_id =~ s/(\w+-)//g;
        } elsif ($field eq 'priority') {
            my $priority = $item->{$field}->{'content'};
            $defect_data->{$bugzilla_col->{$field}}= convert_severity($priority);
            $defect_data->{$field}= convert_priority($priority);
        } elsif ( $field eq 'summary' ){
            $defect_data->{$bugzilla_col->{$field}} = strip_chars($item->{'title'});
        }elsif ( $field eq 'status') {
            my $status = lc($item->{$field}->{'content'});
            $defect_data->{$bugzilla_col->{$field}} = convert_status($status);
        }elsif ( $field eq 'resolution' ){
            my $resolution = lc($item->{$field}->{'content'});
            $defect_data->{$bugzilla_col->{$field}} = convert_resolution($resolution);
        }elsif ( $field eq 'description' ){
            my $desc = strip_chars($item->{$field});
            $defect_data->{$bugzilla_col->{$field}} = html_to_ascii($desc);
        }elsif ( $field eq 'component' ){
            my $value = $item->{$field};
            if ($value eq '' || $value eq 'NULL' ){
                $defect_data->{'component'} ='Misc';
                $defect_data->{'category'} ='Misc';
            }
            if ( @$value[0] eq 'Backend' ){
                $defect_data->{'category'} = 'Backend';
                $defect_data->{'component'} = 'Core';
            }elsif ( @$value[0] eq 'Documentation' ){
                $defect_data->{'category'} = 'Documentation';
                foreach my $data (@{$value}) {
                    if ( $data =~ '^TECH-' ){
                        $data =~ s/^TECH-(.*)/$1/g;
                        $defect_data->{'component'} =$data;
                    }else {
                        $defect_data->{'component'} ='Misc';
                    }
                }
                last;
            }
            if ( grep( /^FUNCTION-/, @{$value} )){
                foreach my $cat_data (@{$value}) {
                    if  ($cat_data =~ /^FUNCTION-/g ){
                        $cat_data =~ s/^FUNCTION-(.*)/$1/g;
                        $defect_data->{'category'} = $cat_data;
                        last;
                    }
                }  
            }elsif (! grep ( /^FUNCTION-/, @{$value} )){
                $defect_data->{'category'} = 'Misc';
            } 
            if ( grep ( /^TECH-/, @{$value} )){
                foreach my $comp_data (@{$value}) {
                    if  ($comp_data =~ /^TECH-/ ){
                        $comp_data =~ s/^TECH-(.*)/$1/g;
                        $defect_data->{'component'} = $comp_data;
                    }
                }
            }
            if (! grep (/TECH-/, @{$value})){
                $defect_data->{'component'} = 'Misc';
            }elsif ( grep (/'Tech,UI'/,@{$value})){
                $defect_data->{'component'} ='UI';
            }elsif ( grep (/Tech/, @{$value})){
                $defect_data->{'component'} = 'Misc';
            }elsif ( (!grep (/FUNCTION/,@{$value} )) && ( grep (/Tech/,@{$value}))){
                $defect_data->{'component'} = 'Misc';
                $defect_data->{'category'} ='Misc';
            }elsif ( (!grep (/FUNCTION/,@{$value} )) && (grep (/^TECH-/,@{$value}))){
                $defect_data->{'category'} ='Misc';
                foreach my $comp (@{$value}){
                    my $comp =~ s/^TECH-(.*)/$1/g;
                    $defect_data->{'component'} = $1;
                }
            }
            
            if ( grep (/'FUNCTION- Dev-Architecture, Design, Testing, Productivity'/, @{$value})){
                $defect_data->{'category'} ='Dev - Internal';
            }elsif ( grep (/'FUNCTION-Security (Users, Groups,  Roles, Multi-tenancy)'/,@{$value})){
                $defect_data->{'category'} ='Security (Users Groups Roles MT)';
            }elsif ( grep (/'FUNCTION-Deployments, Teardown, Updates & Quick Deploy'/, @{$value})){
                 $defect_data->{'category'} = 'Deployments Teardown Updates';
            }elsif ( grep (/'FUNCTION-Scale, Performance \& Stress'/ ,  @{$value})){
                $defect_data->{'category'} = 'Scale Performance \& Stress';
            }elsif ( grep (/'FUNCTION-Install\, CLI and License'/ ,  @{$value})){
                $defect_data->{'category'} = 'Install CLI and License';
            }elsif ( grep (/'FUNCTION-Cloud \(vcloud\, EC2\, T2\, CP\/DE\)'/, @{$value})){
                $defect_data->{'category'} = 'FUNCTION-Cloud';
            }
            #$defect_data->{$bugzilla_col->{$field}} = $value;
        }elsif ( $field eq 'version' ){
            $defect_data->{'found_in_product'} = $product_name;
            my $value = $item->{$field};
            chomp($value);
            my $phase = $value;
            my $version = convert_version($value);
            $defect_data->{$bugzilla_col->{$field}} = $version;
            $defect_data->{'found_in_phase_id'} = convert_phase($phase, $version, $product_name);
        }elsif ($field eq 'fixVersion' ){
            foreach my $value (@{$item->{$field}}){
                my $phase = $value;
                my $fix_by_version = convert_version($value);
                my $fix_by = {'fix_by_product' => $product_name,'fix_by_version' => $fix_by_version , 'fix_by_phase_id' => convert_phase($phase,$fix_by_version,$product_name)};
                push(@{$defect_data->{'fix_by'}}, $fix_by);
            }
        }elsif ( $field eq 'environment' ){
            if ( ref $item->{$field} ne 'HASH'){
                $defect_data->{$bugzilla_col->{$field}} = $item->{$field};
            }else {
                $defect_data->{$bugzilla_col->{$field}} = '';
            }
        }elsif ( $field eq 'created' ){
            $defect_data->{$bugzilla_col->{$field}} = convert_date($item->{$field});
        }elsif ( $field eq 'updated' ){
            $defect_data->{$bugzilla_col->{$field}} = convert_date($item->{$field});
        }elsif ($field eq 'reporter' ){
            my $reporter = convert_username($item->{$field}->{'content'});
            if ($reporter ne 'False'){
                $defect_data->{$bugzilla_col->{$field}} = $reporter;
                #$defect_data->{'qa_contact'} = $reporter;
            }else {
                print "User $item->{$field}->{'content'} does not exist for $field for bug id $external_id.\n";
                exit;
            }
        }elsif ($field eq 'assignee' ){
            my $assigned_to = convert_username($item->{$field}->{'content'});
            print "AAA: $assigned_to\n";
            if ( $assigned_to ne 'False' ){
                $defect_data->{$bugzilla_col->{$field}} = $assigned_to;
            }else {
                print "User $item->{$field}->{'content'} does not exist for $field for bug id $external_id.\n";
                exit;
            }
        }elsif ( $field eq 'type' ){
            $defect_data->{'cf_type'} = $item->{$field}->{'content'};
        }elsif ( $field eq 'due' ){
            if ( ref $item->{$field} ne 'HASH'){
                $defect_data->{$bugzilla_col->{$field}} = $item->{$field};
            }else {
                $defect_data->{$bugzilla_col->{$field}} = '';
            }
        }elsif ( $field eq 'comments' ){
            #$defect_data->{$bugzilla_col->{$field}} = $item->{$field}->{'comment'};
            my $value = {};
            $value = $item->{$field};
            #$value = strip_chars($item->{$field});
            foreach my $keys (%{$value}){
                if ( ref $value->{$keys} eq 'HASH' ){
                    my $who = $value->{$keys}->{'author'};
                    my $when=convert_date($value->{$keys}->{'created'});
                    my $text = html_to_ascii($value->{$keys}->{'content'});
                    if ($text){
                        my $comment = {'when' => $when,
                                       'who' => $who,
                                       'text' => $text};
                        push(@{$bug_data->{$external_id}->{'comments'}},$comment) if defined $bug_data->{$external_id};
                    }
                }else {
                    foreach my $arr (@{$value->{$keys}}){
                        my $who = $arr->{'author'};
                        my $when=convert_date($arr->{'created'});
                        my $text = html_to_ascii($arr->{'content'});
                        if ($text){
                            my $comment = {'when' => $when,
                                           'who' => $who,
                                           'text' => $text};
                            push(@{$bug_data->{$external_id}->{'comments'}},$comment) if defined $bug_data->{$external_id};
                       }#end if
                    }#end inside else foreach
                }#end else
            }#end outer foreach
        }#end elsif
         $bug_data->{$external_id} = $defect_data;
    }
    my $customfield = $item->{'customfields'};
    foreach my $branch (%{$customfield}){
        foreach my $custom (@{$customfield->{$branch}}){
            if ( $custom->{'customfieldname'} eq 'Cc' ){
                my $cc = validate_username($custom->{'customfieldvalues'}->{'customfieldvalue'});
                if ( $cc ne '' ){
                    push(@{$bug_data->{$external_id}->{'cc'}},$cc) if defined $bug_data->{$external_id};
                }else {
                    print "CC Field value $custom->{'customfieldvalues'}->{'customfieldvalue'} does not exist for Bug Id $external_id. Please check\n";
                    exit;
                }
            }# end of if
        }#end of inner foreach
    }#end of outer foreach
}
#print Dumper $bug_data;
foreach my $st_id (sort {$a cmp $b} keys %$bug_data) {
    my $index = lsearch($imported_already, $st_id);
    next unless $index == -1;
    print "working on: $st_id\n";
   
    if ($really_do) {
        my $result;
        my $soapresult = $proxy->call('Bug.create', $bug_data->{$st_id} );
        _die_on_fault($soapresult);
        
        $result = $soapresult->result;
        if (ref($result) eq 'HASH') {
            foreach (keys(%$result)) {
                print "$_: $$result{$_} for: $st_id\n";
                open(LOG, ">>$log_filename") or die "Can't open file: $!";
                print LOG  "$_: $$result{$_} for: $st_id\n";
                &VMware::ImportExternal::logImportedDefect({
                    product     => $bug_data->{$st_id}->{'product'},
                    external_id => $st_id,
                    bug_id      => $$result{$_},
                    timestamp   => $timestamp });
            }
        }else {
            print "$result for: $st_id\n";
            &VMware::ImportExternal::logImportedDefect({
                product     => $bug_data->{$st_id}->{'product'},
                external_id => $st_id,
                bug_id      => $result,
                timestamp   => $timestamp });
        }
    }
}


sub _die_on_fault {
    my $soapresult = shift;

    if ($soapresult->fault) {
        my ($package, $filename, $line) = caller;
        warn $soapresult->faultcode . ' ' . $soapresult->faultstring .
            " in SOAP call near $filename line $line.\n";
    }
}
sub help(){
print <<EOF
Usage: AppD_Import.pl
This script import bugs to the Bugzilla using API.
Options:
You need to pass below options here.

-data_file      Data file name which contains all the data for import in .xml format.
-uri            Need to pass Url of bugzilla server, where you want to import the data.
                Url must look like 'http://gargv-bz3.eng.vmware.com/xmlrpc.cgi'
-login          Provide login name
-password       Provide password
-rememberlogin  Must be either YES or NO.
-help           For help text.

example-

$0 -data_file test.xls -uri 'https://bugzilla-dev.eng.vmware.com/xmlrpc.cgi' -login kpmc -password vmware -rememberlogin YES
EOF
}
