#!/usr/bin/perl
use warnings;
no warnings qw/uninitialized/;
use strict;

################################################################################
{
    package RSSCheck;

    use utf8;
    use Glib qw/TRUE FALSE/;
    use Gtk2 '-init';
    use Gtk2::Notify -init, 'SS.lv feed reader';
    use POSIX qw/strftime/;
    use IO::Async::Loop::Glib;
    use IO::Async::Timer::Periodic;
    use IO::Async::Notifier;
    use XML::Simple;
    use Digest::MD5 qw(md5_hex);
    use Storable;
    use Scalar::Util qw(weaken);
    
    require "JhCurl.pl";
    binmode STDOUT, ":utf8";
    binmode STDERR, ":utf8";

    sub new{
	    my ($proto)=@_;
	    my $class = ref($proto) || $proto;
	    my $self  = {};

        $self->{price_min}=30;
        $self->{price_max}=100;
        
        $self->{rooms_min}=1;
        $self->{rooms_max}=3;
        
        $self->{space_min}=25;
        $self->{space_max}=60;

        $self->{price_ratio_max}=2.9;
        $self->{price_ratio_min}=0.7;

        $self->{recheck_time}=30;

        $self->{eur_conv}=0.69;

        $self->{next_id}=1;

        $self->{tmp_dir}="/tmp/";

        $self->{icon}="dialog-question";
        $self->{icon_info}="dialog-info";
        $self->{icon_warning}="dialog-warning";
        $self->{icon_error}="dialog-error";

        $self->{curl}=JhCurl->new();

	    bless($self, $class);
	    return $self;
    }
    
    sub loop {

        my ($self) =@_;
        $self->{loop} = IO::Async::Loop::Glib->new();
        $self->{notifier} = IO::Async::Notifier->new;

        $self->{popup} = Gtk2::Notify->new('ss.lv notifications', 'Started SS.lv notification tool', $self->{icon});
        $self->{popup}->set_timeout(6000);

        $self->{status_icon} = Gtk2::StatusIcon->new_from_icon_name($self->{icon});

        # Menu
        $self->{menu} = Gtk2::Menu->new();
        my $menuItem = Gtk2::ImageMenuItem->new_with_label("SS.lv/ZIP.lv notification tool (http://www.janhouse.lv)");
        $self->{menu}->append($menuItem);

        $menuItem = Gtk2::ImageMenuItem->new_from_stock('gtk-quit');
        $menuItem->signal_connect('activate', $self->_capture_weakself(sub { shift->delete_event(@_) }), $self->{status_icon});
        $self->{menu}->append($menuItem);



        #$status_icon->signal_connect('activate', \&show_hide_window);
        $self->{status_icon}->signal_connect('popup-menu', $self->_capture_weakself(sub { shift->popup_menu_cb(@_) }), $self->{menu});
        $self->{status_icon}->set_visible(1);
        $self->{status_icon}->set_tooltip("0 unread entries.");

	    $self->{recheck_timer} = IO::Async::Timer::Periodic->new(
		    interval => $self->{recheck_time},
		    on_tick => sub { $self->check_entries(@_); },
            first_interval => 0,
	    );
        
        $self->{recheck_timer}->start;
	    $self->{loop}->add($self->{recheck_timer});

        $self->{loop}->loop_forever();

    }

    sub load_rss_ss {
        my ($self) =@_;
        $self->err("Prepairing to load feed.");
        my $request=$self->{curl}->get("http://www.ss.lv/lv/real-estate/flats/riga/rss/");
        return 0 if $request==0;
        $self->{curldat}->{rss_ss}=$self->{curl}->{curldat};
        return 1;
    }
    
    sub load_rss_zip {
        my ($self) =@_;
        $self->err("Prepairing to load feed.");
        my $request=$self->{curl}->get("http://www.zip.lv/rss/?s=a424866d531cedbc228ea0165de4a6bd");
        return 0 if $request==0;
        $self->{curldat}->{rss_zip}=$self->{curl}->{curldat};
        return 1;
    }
    
    

    sub read_xml {
        my ($self, $target) =@_;
        
        $self->err("Parsing XML for $target....");
        my $xs = XML::Simple->new();
        $self->{$target} = $xs->XMLin($self->{curldat}->{$target});
        do{ $self->err("Parsing XML failed."); return 0 }if $self->{$target}==0;
        $self->err("Found ".scalar(keys $self->{$target}->{channel}->{item})." entries.");
    }

    sub isnumber 
    {
        my $self=shift;
        shift =~ /^-?\d+\.?\d*$/;
    }


######## Quit subroutine
sub delete_event
{
	print "\nThank you for using SS.lv notification tool made by Janhouse.\nPlease visit http://www.janhouse.lv/ .\n\n";
	exit;
}

######### Tray menu subroutine
sub popup_menu_cb {
   my ($self, $widget, $button, $time, $menu) = @_;

   if ($button == 3) {
	   my ($x, $y, $push_in) = Gtk2::StatusIcon::position_menu($menu, $widget);
	   $menu->show_all();
	   $menu->popup( undef, undef, sub{return ($x,$y,0)}, undef, 0, $time );
       if($self->{unread}>1){
            $self->icon_read_normal();
       }
   }
}

sub update_status_title {
    my ($self) =@_;
    $self->{status_icon}->set_tooltip($self->{unread}." unread entries.");    
}

sub icon_read_normal {
    my ($self) =@_;
    $self->{status_icon}->set_from_icon_name($self->{icon});
    $self->{status_icon}->set_blinking(FALSE);   
}

sub icon_read {
    my ($self) =@_;
    $self->{status_icon}->set_from_icon_name($self->{icon});
    $self->{status_icon}->set_blinking(FALSE);
    $self->{unread}--;
    $self->update_status_title();
    
}

sub icon_unread {
    my ($self) =@_;
    $self->{status_icon}->set_from_icon_name($self->{icon_error});
    $self->{status_icon}->set_blinking(TRUE);
    $self->{unread}++;
    $self->update_status_title();
}


sub get_image {
    my ($self, $image, $cid) =@_;

    $self->err("Going to look for image to use with notification.");
    my $request=$self->{curl}->get($image);
    return 0 if $request==0;

    my $file_type=$self->{curl}->curl_get_type();
    if($file_type eq 0 or $file_type ne "image/jpeg"){ $self->err("Downloaded content is not of type image/jpeg: ".$file_type); return 0; }
    my $image_p=$self->{tmp_dir}."adv_".$cid.".jpg";
    return 0 if not $self->write_file($image_p, $self->{curl}->response);
    return $image_p;
}

sub check_entries {
    my ($self) =@_;
    
    $self->err("\n**************************************************\nLooking for new entries.");
    ######################################### SS.lv
    my $rs=$self->load_rss_ss();
    if($rs!=0){
    
    $self->read_xml("rss_ss");
    #use Data::Dumper;
    #print Dumper $self->{"rss_ss"}->{channel}->{item};
    foreach my $entry (values @{$self->{"rss_ss"}->{channel}->{item}}){
        
        next if not my $rajons=$self->match(qr/Rajons: <b>(.*?)<\/b><br\/>/ms, $entry->{description}, 0);
        next if not my $istabas=$self->match(qr/Ist.: <b>(.*?)<\/b><br\/>/ms, $entry->{description}, 0);
        next if not my $platiba=$self->match(qr/m2: <b>(.*?)<\/b><br\/>/ms, $entry->{description}, 0);
        next if not my $cena=$self->match(qr/Cena: <b>(.*?) Ls\/m.n.<\/b><br\/>/ms, $entry->{description}, 0);

        next if not $self->isnumber(@$istabas[0]) or not $self->isnumber(@$platiba[0]) or not $self->isnumber(@$cena[0]);

        my $message="SS.lv; Rajons: ".@$rajons[0]."; Istabas: ".@$istabas[0]."; Platiba: ".@$platiba[0]."; Cena: ".@$cena[0];
        my $price_ratio=sprintf("%.2f", @$cena[0]/@$platiba[0]);
        $message.="; Cena/m2: ".$price_ratio;

        if(@$istabas[0] >= $self->{rooms_min} and @$istabas[0] <= $self->{rooms_max} 
        and @$platiba[0] >= $self->{space_min} and @$platiba[0] <= $self->{space_max}
        and @$cena[0] >= $self->{price_min} and @$cena[0] <= $self->{price_max} 
        and $self->{price_ratio_max} >= $price_ratio and $self->{price_ratio_min} <= $price_ratio)
        {

            my $hashy=md5_hex($entry->{link});
            my $found=0;
            foreach my $keyz (keys %{$self->{menu_items}}){
                $found=1 if $keyz eq $hashy;
            }
            next if $found==1;

            # MATCH
            $self->err("MATCH! ".$message." - ".$entry->{link});
            
            # Get image for the entry
            if(my $image=$self->match(qr/<img align=right border=0 src="(.*?)" width=/ms, $entry->{description}, 0)){
                # IF got image
                if(my $img_link=$self->get_image(@$image[0], $self->{next_id})){
                    $self->{matches}->{$self->{next_id}}->{icon}=$img_link;
                }
            }
            $self->{matches}->{$self->{next_id}}->{hash}=$hashy;
            $self->{matches}->{$self->{next_id}}->{unread}=1;
            $self->{matches}->{$self->{next_id}}->{link}=$entry->{link};
            $self->{matches}->{$self->{next_id}}->{title}=$entry->{title};
            $self->{matches}->{$self->{next_id}}->{message}="SS.lv\nRajons: ".@$rajons[0]."\nIstabas: ".@$istabas[0]."\nPlatiba: ".@$platiba[0]."\nCena: ".@$cena[0]." Ls\nKvadratmetra: ".$price_ratio." Ls";
            $self->add_entry($self->{next_id}, $hashy);
            
            $self->{next_id}++;
        }else{
            # NOT MATCH
            $self->err($message);
        }

    }
    }
    ################################ ZIP.lv
    my $zip=$self->load_rss_zip();
    if($zip!=0){
    
    $self->err("Looping through entries to find if any matches can be found.");
    $self->read_xml("rss_zip");

    foreach my $entry (values @{$self->{"rss_zip"}->{channel}->{item}}){
        #$self->err($entry->{description});
        next if not my $rajons=$self->match(qr/<b>Rīga, (.*?)(, |<br)/ms, $entry->{description}, 0);
        #$self->err("Got rajons: ".@$rajons[0]);
        next if not my $istabas=$self->match(qr/<b>Izīrē (.*?) istabu dzīvokli<\/b>/ms, $entry->{description}, 0);
        #$self->err("Got istabas: ".@$istabas[0]);
        next if not my $platiba=$self->match(qr/<b>(\d*?)m²<\/b><br \/>/ms, $entry->{description}, 0);
        #$self->err("Got platiba: ".@$platiba[0]);
        next if not my $cena=$self->match(qr/<b>(\d*?) (EUR|LVL)<\/b>/ms, $entry->{description}, 0);
        #$self->err("Got cena: ".@$cena[0].@$cena[1]);

        next if not $self->isnumber(@$istabas[0]) or not $self->isnumber(@$platiba[0]) or not $self->isnumber(@$cena[0]);
        #$self->err("All numbers");
        if(@$cena[1] eq "EUR"){
            @$cena[0]=sprintf("%.2f", @$cena[0]*$self->{eur_conv});
        }

        my $message="ZIP.lv; Rajons: ".@$rajons[0]."; Istabas: ".@$istabas[0]."; Platiba: ".@$platiba[0]."; Cena: ".@$cena[0];
        my $price_ratio=sprintf("%.2f", @$cena[0]/@$platiba[0]);
        $message.="; Cena/m2: ".$price_ratio;

        if(@$istabas[0] >= $self->{rooms_min} and @$istabas[0] <= $self->{rooms_max} 
        and @$platiba[0] >= $self->{space_min} and @$platiba[0] <= $self->{space_max}
        and @$cena[0] >= $self->{price_min} and @$cena[0] <= $self->{price_max} 
        and $self->{price_ratio_max} >= $price_ratio and $self->{price_ratio_min} <= $price_ratio)
        {

            my $hashy=md5_hex($entry->{link});
            my $found=0;
            foreach my $keyz (keys %{$self->{menu_items}}){
                $found=1 if $keyz eq $hashy;
            }
            next if $found==1;

            # MATCH
            $self->err("MATCH! ".$message." - ".$entry->{link});
            
            # Get image for the entry
            if(my $image=$self->match(qr/<img src="(.*?)" alt=""/ms, $entry->{description}, 0)){
                # IF got image
                if(my $img_link=$self->get_image(@$image[0], $self->{next_id})){
                    $self->{matches}->{$self->{next_id}}->{icon}=$img_link;
                }
            }
            $self->{matches}->{$self->{next_id}}->{hash}=$hashy;
            $self->{matches}->{$self->{next_id}}->{unread}=1;
            $self->{matches}->{$self->{next_id}}->{link}=$entry->{link};
            $self->{matches}->{$self->{next_id}}->{title}=$entry->{title};
            $self->{matches}->{$self->{next_id}}->{message}="ZIP.lv\nRajons: ".@$rajons[0]."\nIstabas: ".@$istabas[0]."\nPlatiba: ".@$platiba[0]."\nCena: ".@$cena[0]." Ls\nKvadratmetra: ".$price_ratio." Ls";
            $self->add_entry($self->{next_id}, $hashy);
            
            $self->{next_id}++;
        }else{
            # NOT MATCH
            $self->err($message);
        }

    }
    }
    
    $self->err("Finished checking for matches.");
    return 1;
}

sub add_entry {
    my ($self, $cid, $hash)=@_;
    $self->{menu_items}->{$hash} = Gtk2::ImageMenuItem->new_with_label($self->{matches}->{$cid}->{message}."\n\n".$self->{matches}->{$cid}->{title});

    my $image = Gtk2::Image->new_from_file ($self->{matches}->{$cid}->{icon});
    my $pixbuf=$image->get_pixbuf;

    $self->{menu_items}->{$hash}->set_image( Gtk2::Image->new_from_pixbuf( $pixbuf) );
    $self->{menu_items}->{$hash}->signal_connect('activate', $self->_capture_weakself(sub { shift->open_link($cid) }), $self->{status_icon});
    $self->{menu}->append($self->{menu_items}->{$hash});
    $self->show_popup($cid);
    $self->icon_unread();
    
     $self->{loop}->spawn_child(
    code => sub {
       system "aplay /home/janhouse/.sounds/Borealis/K3b_success.wav";
       return 1;
    },
    on_exit => sub {   },
 );

}

sub show_popup {
    my ($self, $cid)=@_;
    
    my $popup = Gtk2::Notify->new("NEW MATCH!", $self->{matches}->{$self->{next_id}}->{message}."\n\n".$self->{matches}->{$cid}->{title}, $self->{matches}->{$cid}->{icon});
    $popup->set_timeout(6000);
        
    #$popup->clear_actions();
    $popup->add_action("show", "Show in browser", $self->_capture_weakself(sub { $_[0]->open_link }));
    $popup->add_action("read", "Mark as read", $self->_capture_weakself(sub { $_[0]->mark_read }));
    #$popup->update("NEW SS.LV MATCH!", $self->{matches}->{$self->{next_id}}->{message}."\n\n".$self->{matches}->{$cid}->{title}, $self->{matches}->{$cid}->{icon});
    $popup->show;
    
}

    sub _capture_weakself
    {
        my $self = shift;
        my ( $code ) = @_;   # actually bare method names work too

        weaken $self;

        return sub { $self->$code( @_ ) };
    }

    sub open_link{
        my ($self, $cid)=@_;
        
        $self->err("ID: $cid; ".$self->{matches}->{$cid}->{hash}." ** ".$self->{menu_items}->{$self->{matches}->{$cid}->{hash}});
        
        #$self->{menu_items}->{$self->{matches}->{$cid}->{hash}}->gtk_widget_destroy();
        $self->{menu}->remove($self->{menu_items}->{$self->{matches}->{$cid}->{hash}});
     $self->icon_read();
     
     my @args=($self->{matches}->{$cid}->{link});
     system "xdg-open", @args;
     
     
    }

    sub mark_read{
        my ($self)=@_;
        
        $self->err("pacaniii");
        
        #print "trololo\n\n\n";
        #my ($self)=@_;
     #return $self->match; 
     #return 0;
    }

    sub match{
        my ($self, $regexp, $data, $what)=@_;

        if(my @stuff=$data =~ $regexp){
            my @matches;
            my $last=0;
            for(my $i=1;1==1;$i++){
                eval"\$last=1 if(not defined(\$$i)); push(\@matches, \$$i);"; warn $@ if $@;
                last if $last == 1;
            }
            #$self->err(	'Successfully matched '.$matches[$what].'...');
            return \@matches;
        }else{
            #$self->err('Failed to match '.$what.'...');
            return 0;
        }
    }

    sub read_file
    {
	    my ($self, $f) = @_;
	    if(open(F, "< $f")){
		    my $f = do { local $/; <F> };
		    close F;
		    return $f;
	    }else{
		    $self->err("Failed opening file ".$f.": ".$1);
		    return 0;
	    }
    }

    sub write_file {
	    my ($self, $path, $data) = @_;
	    if(open(FILE, ">", $path)){
		    print FILE $data;
		    if(close(FILE)){
			    $self->err('Succeeded writing file: '.$path);
		    }else{
			    $self->err("Failed to close file: $path\nError message: $!.");
			    return 0;
		    }
	    }else{
		    $self->err("Failed to write file: $path\nError message: $!.");
		    return 0;
	    }
	    return 1;
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

    my $client=RSSCheck->new();
    $client->loop;

1;
