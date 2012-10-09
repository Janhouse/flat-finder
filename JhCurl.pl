#!/usr/bin/perl
use warnings;
no warnings qw/uninitialized/;
use strict;

################################################################################
{
    package JhCurl;

    use WWW::Curl::Easy;
    use WWW::Curl::Form;

    sub new {
	    my ($proto, $way, $name, $config)=@_;
	    my $class = ref($proto) || $proto;
	    my $self  = {};


	    $self->{curl_connect}=exists $config->{tuper}->{curl_connect} ? $config->{tuper}->{curl_connect} : 5;
	    $self->{curl_timeout}=exists $config->{tuper}->{curl_timeout} ? $config->{tuper}->{curl_timeout} : 60;
	    $self->{curl_wait}=exists $config->{tuper}->{curl_wait} ? $config->{tuper}->{curl_wait} : 1;
	    $self->{curl_times}=exists $config->{tuper}->{curl_times} ? $config->{tuper}->{curl_times} : 5;
	    $self->{cookies}=exists $config->{cookies}->{'cookie_'.$name} ? $config->{cookies}->{'cookie_'.$name} : undef;
	    $self->{cookie_jar}=exists $config->{paths}->{cookie_jar} ? $config->{paths}->{cookie_jar} : undef;
	    $self->{curl_headers}=exists $config->{tuper}->{curl_headers} ? $config->{tuper}->{curl_headers} : undef;
	    $self->{useragent}=exists $config->{tuper}->{curl_useragent} ? $config->{tuper}->{curl_useragent} : undef;
        $self->{ip}=undef;
        if(exists $config->{tuper}->{download_ip} or exists $config->{tuper}->{upload_ip}){
            $self->{ip}=$way eq 'download' ? $config->{tuper}->{download_ip} : $config->{tuper}->{upload_ip};
        }

	    $self->{curldat}=undef;
	    $self->{response_type}=undef;
	    $self->{referer}=undef;

        $self->{ignore_status_500}=exists $config->{tuper}->{ignore_status_500} ? $config->{tuper}->{ignore_status_500} : 0;

	    $self->{curl}=new WWW::Curl::Easy;
	    $self->{curl}->setopt(CURLOPT_FOLLOWLOCATION, 1);

    #	$self->{curl}->setopt(CURLOPT_RETURNTRANSFER, 1);
	    $self->{curl}->setopt(CURLOPT_SSL_VERIFYPEER, 0);

	    $self->{curl}->setopt(CURLOPT_VERBOSE, 0);

	    $self->{curl}->setopt(CURLOPT_TIMEOUT, $self->{curl_timeout}) if defined $self->{curl_timeout};
	    $self->{curl}->setopt(CURLOPT_CONNECTTIMEOUT, $self->{curl_connect}) if defined $self->{curl_connect};

	    $self->{curl}->setopt(CURLOPT_COOKIEFILE, $self->{cookie_jar}) if defined $self->{cookie_jar};
	    $self->{curl}->setopt(CURLOPT_COOKIEJAR, $self->{cookie_jar}) if defined $self->{cookie_jar};

	    $self->{curl}->setopt(CURLOPT_COOKIE, $self->{cookies}) if defined $self->{cookies};
        
        if(defined $self->{curl_headers}){
            my @array;
            $array[0]=$self->{curl_headers};
            $self->{curl}->setopt(CURLOPT_HTTPHEADER, \@array);
        }

	    $self->{curl}->setopt(CURLOPT_INTERFACE, $self->{ip}) if defined $self->{ip} and $self->{ip}ne"";
	    $self->{curl}->setopt(CURLOPT_REFERER, $self->{referer}) if defined $self->{referer};
	    $self->{curl}->setopt(CURLOPT_USERAGENT, $self->{useragent}) if defined $self->{useragent};

	    bless($self, $class);
	    return $self;
    }

    sub form_new {
	    my ($self)=@_;
	    if(not exists $self->{curlform}){
		    $self->{curlform}=WWW::Curl::Form->new;
	    }else{
		    delete $self->{curlform};
		    $self->{curlform}=WWW::Curl::Form->new;
	    }
    }


    sub form_add {
	    my ($self, $name, $value)=@_;
	    if(not exists $self->{curlform}){
		    $self->form_new;
	    }
	    $self->{curlform}->formadd($name, $value);
    }


    sub form_add_file {
	    my ($self, $name, $value, $type)=@_;
	    if(not exists $self->{curlform}){
		    $self->form_new;
	    }
	    if(not -f $value){
		    $self->err("Can not add $name ($type) file to POST from beacause it doesn't exist: $value");
		    return 0;
	    }
	    $self->{curlform}->formaddfile($value, $name, $type);
	    return 1;
    }

    sub get {
	    my ($self, $link)=@_;
	    $self->{curl}->setopt(CURLOPT_REFERER, $self->{referer});
	    $self->{curl}->setopt(CURLOPT_POST, 0);
	    $self->{curl}->setopt(CURLOPT_URL, $link);
	    $self->err('Requesting page: '.$link);
	    my $request=$self->curl_request_page(0);
	    $self->{referer}=$link;
	    return $request;

    }

    sub post {
	    my ($self, $link)=@_;
	    $self->{curl}->setopt(CURLOPT_REFERER, $self->{referer});
	    $self->{curl}->setopt(CURLOPT_POST, 1);
	    $self->{curl}->setopt(CURLOPT_HTTPPOST, $self->{curlform});
	    $self->{curl}->setopt(CURLOPT_URL, $link);
	    $self->err('Requesting page: '.$link);
	    my $request=$self->curl_request_page(0);
	    $self->{referer}=$link;
	    return $request;

    }

    sub curl_get_type {
	    my ($self)=@_;
	    $self->{response_type}=undef;
	    $self->{response_type} = lc($self->{curl}->getinfo(CURLINFO_CONTENT_TYPE));
	    if($self->{response_type} eq 0){ $self->err('Failed to get response type'); return 0;}
	    $self->err('Response type: '.$self->{response_type});
	    return $self->{response_type};
    }

    sub curl_write_data {
	    my ($self, $curlresp)=@_;
	    $self->{curldat}.=$curlresp;
	    return length($curlresp);
    }

    sub curl_request_page{
	    my ($self, $time)=@_;
	    $time++;

	    $self->{curldat}=undef;
	    use Scalar::Util qw(weaken);
	    weaken $self;
	    $self->{curl}->setopt(CURLOPT_WRITEFUNCTION, sub { $self->curl_write_data(@_) });

	    my $retcode = $self->{curl}->perform;
	    if ($retcode != 0) {
		    $self->err("An error happened at iteration ".$time."/".$self->{curl_times}.": ".$self->{curl}->strerror($retcode)." ($retcode)...");
		    if($time==$self->{curl_times}){
			    $self->err("Failed to get page ".$time." times.");
			    return 0;
		    }else{
			    $self->err("Waiting ".$self->{curl_wait}." seconds and retrying...");
			    sleep($self->{curl_wait});
			    $self->curl_request_page($time);
		    }
	    }else{
		    my $response_code = $self->{curl}->getinfo(CURLINFO_HTTP_CODE);
		    if(($self->{ignore_status_500}==0 and $response_code==500) or $response_code==502 or $response_code==404 or $response_code==403){
			    $self->err("An error happened at iteration ".$time."/".$self->{curl_times}.": Got bad response code (".$response_code.")...");
			    if($time==$self->{curl_times}){
				    $self->err("Failed to get page ".$time." times.");
				    return 0;
			    }else{
				    $self->err("Waiting ".$self->{curl_wait}." seconds and retrying...");
				    sleep($self->{curl_wait});
				    $self->curl_request_page($time);
			    }
		    }else{
			    $self->err('Transfer went ok, got response code '.$response_code.'...');
		    }
	    }
    }

    sub response {
        my ($self)=@_;
        return $self->{curldat};
    }

    sub err{
	    my ($self, $mesg)=@_;
	    #$self->{_err}=undef if(not exists $self->{_err});
	    #$self->{_err}.=$mesg."\n";
	    print STDERR $mesg."\n";
    }

    sub DESTROY {

    }

}
1;
