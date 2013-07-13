#!/usr/bin/perl
package AnyEvent::MultiDownload;
use strict;
use AnyEvent::HTTP;
use AnyEvent::Util;
use AnyEvent::Socket;
use AE;
use Moo;
use File::Slurp;
use List::Util qw/shuffle/;

our $VERSION = '0.10';

my %all;

has dlname => (
    is => 'ro',
    isa => sub {
        die "文件存在" if -e $_[0];
    },
    required => 1,
);

has url => (
    is  => 'ro',
    required => 1,
);

has mirror => (
    is => 'rw',
    predicate => 1,
    isa => sub {
        return 1 if ref $_[0] eq 'ARRAY';
    },
);

has on_finish => (
    is => 'rw',
    required => 1,
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    }
);

has on_error => (
    is => 'rw',
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    },
    default => sub {  sub { 1 } },
);

has on_seg_finish => (
    is => 'rw',
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    },
    default => sub {  
        return sub { $_[-1]->(1) } 
    },
);

has seg_size => is => 'rw', default => sub { 2 * 1024 * 1024 };
has timeout  => is => 'rw', default => sub { 60 };
has recurse  => is => 'rw', default => sub { 6 }; 
has signal   => is => 'rw';

sub BUILD {
    my $self = shift;
    my $dlname = $self->dlname;
    $all{$dlname} = 1,
    my $s = AE::signal INT =>  sub {
        for my $file (keys %all) {
            while( glob("$file.*")) {
                unlink $_;
            }
            delete $all{$file};
        }
        exit;
    };
    $self->signal($s);
};

sub get_file_length {
    my $self = shift;
    my $cb   = shift;

    
    my ($len, $hdr);
    my $cv = AE::cv {
        $cb->($len, $hdr)
    };

    my $url = $self->url;
    my $fetch_len; $fetch_len = sub {
        my $retry = shift || 0;
        my $ev; $ev = http_head $url,
            timeout => $self->timeout,
            recurse => $self->recurse,
            sub {
                (undef, $hdr) = @_;
                undef $ev;
                if ($retry < 3) {
                    $fetch_len->(++$retry); 
                    return;
                }
                if ($hdr->{Status} =~ /^2/) {
                    $len = $hdr->{'content-length'};
                }
                elsif ($hdr->{Status} =~ /^404/) {
                    $self->on_error->("$url 文件不存在");
                }
                else {
                    $self->on_error->("取 $url 长度失败");
                }
                $cv->end;
            };
    };
    $cv->begin;
    $fetch_len->(0);
}

sub multi_get_file  {
    my ($self, $cb)   = @_;

    $self->get_file_length( sub {
        my ($len, $hdr) = @_;

        my $ranges = $self->split_range($len);

        my $cv = AE::cv { 
            my $cv = shift;
            $self->on_join($ranges, $self->dlname);
        };

        # 事件开始, 但这个回调会在最后才调用.
        $cv->begin;
        for my $range (@$ranges) {
            $cv->begin;
            my $uri = $self->shuffle_url;
            $self->fetch->( $cv, $uri, $range, 0 ) ;
        }
        $cv->end;
    });
}

sub on_join {
    my ($self, $ranges) = @_;
    my $dlname = $self->dlname;

    AnyEvent::Util::fork_call {
        local $/;
        open my $wfh, '>:raw', $dlname or die "$dlname:$!";
        for my $range ( @$ranges ) {
            my $tmpf = $dlname . '.' . $range->{chunk};
            open my $rfh, '<:raw', $tmpf or die "$tmpf:$!";
            my $content = <$rfh>;
            print $wfh $content;
            close $rfh;
            unlink $tmpf;
        }
        return -s $dlname
    } sub {
        $self->on_finish->($_[0]);
    }
}
sub shuffle_url {
    my $self = shift;
    my @urls;
    @urls = @{ $self->mirror } if $self->has_mirror;
    push @urls, $self->url;
    return (shuffle @urls)[0];
}

sub fetch {
    my $self = shift;
    return sub {
        my ($cv, $url, $range, $retry) = @_; 
        $retry ||= 0;
        my $ofs  = $range->{ofs};
        my $tail = $range->{tail};
        my $tmpf = $self->dlname. '.' .$range->{chunk};
        unlink $tmpf;

        my $buf;
        my $ev; $ev = http_get $url,
            timeout => $self->timeout,
            recurse => $self->recurse,
            persistent  => 1,
            keepalive   => 1,
            headers => { 
                Range => "bytes=$ofs-$tail" 
            },
            on_body => sub {
                my ($partial_body, $hdr) = @_;
                my $status = $hdr->{Status};
                if ( $status == 200 || $status == 206 || $status == 416 ) {
                    $buf += length($partial_body) if $range->{chunk} == 1;
                    write_file( $tmpf, {append => 1}, $partial_body ); # 追加写文件
                }
                return 1;
            },
            sub {
                my ($hdl, $hdr) = @_;

                my $status = $hdr->{Status};

                if ( $retry > 3 ) {
                    $cv->on_error->("地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载失败 $retry");
                    $cv->end;
                }

                if ($status == 200 || $status == 206 || $status == 416) {
                    my $size = -s $tmpf;
                    if ( $size == ($tail-$ofs+1) ) {
                        $self->on_seg_finish->($hdl, $tmpf, $size, sub {
                            my $result = shift;
                            if (!$result) {
                                AE::log debug => "地址 $url 的块 $range->{chunk} 检查失败, 范围 bytes=$ofs-$tail 重试";
                                $self->fetch->($cv, $self->shuffle_url, $range, ++$retry ) 
                            }
                            else {
                                AE::log debug => "地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载完成";
                                $cv->end;
                            }
                        });
                    }
                    else {
                        AE::log warn => "地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载失败, 第 $retry 次重试";
                        $self->fetch->($cv, $self->shuffle_url, $range, ++$retry ) 
                    }
                } elsif ($status == 412 or $status == 500 or $status == 503 or $status =~ /^59/) {
                        AE::log warn => "地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载失败, 第 $retry 次重试";
                        $self->fetch->($cv, $self->shuffle_url, $range, ++$retry ) 
                } 
                else {
                    $cv->end;

                }
                undef $ev;
            };
    };
}

sub clean {
    my $self = shift;
    return sub {
        for my $range ( @{ $self->ranges } ) {
            my $dlname = $self->dlname . '.' . $range->{chunk};
            unlink $dlname;
        }
        exit;
    };
}

sub split_range {
    my $self    = shift;
    my $length  = shift;

    # 每个请求的段大小的范围,字节
    my $seg_size   = $self->seg_size;
    my $segments   = int($length / $seg_size);

    # 要处理的字节的总数
    my $len_remain = $length;

    my @ranges;
    my $chunk = 0;
    while ( $len_remain > 0 ) {
        # 每个 segment  的大小
        my $seg_len = $seg_size;

        # 偏移长度
        my $ofs = $length - $len_remain;
        
        # 剩余字节
        $len_remain -= $seg_len;

        my $tail  = $ofs + $seg_len - 1; 
        if ( $length-1  < $tail) {
            $tail = $length-1;
        }

        my $Range = "bytes=$ofs-" . $tail ;

        push( @ranges, {
                 ofs   => $ofs,
                 tail  => $tail,
                 chunk => $chunk,
                } 
        );
        $chunk++;
    }
    return \@ranges;
}

1;

__END__

=pod
 
=encoding utf8

=head1 NAME

AnyEvent::MultiDownloadu - 非阻塞的多线程多地址文件下载的模块

=head1 SYNOPSIS

这是一个全非阻塞的多线程多地址文件下载的模块, 可以象下面这个应用一样,同时下载多个文件,并且整个过程都是异步事件解发,不会阻塞主进程.

下面是个简单的例子,同时从多个地址下载同一个文件.

    use AE;
    use AnyEvent::MultiDownload;
    
    my $cv = AE::cv;
    my $MultiDown = AnyEvent::MultiDownload->new( 
        url     => 'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 
        mirror  => ['http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso'],
        dlname  => '/tmp/ubuntu.iso',
        seg_size => 1 * 1024 * 1024, # 1M
        on_seg_finish => sub {
            my ($hdr, $seg_path, $size, $cb) = @_;
            $cb->(1);
        },
        on_finish => sub {
            my $len = shift;
            $cv->send;
        },
        on_error => sub {
            my $error = shift;
            $cv->end;
        }
    )->multi_get_file;
    
    $cv->recv;


下面是异步同时下载多个文件的实例. 整个过程异步.

    use AE;
    use AnyEvent::MultiDownload;
    
    my $cv = AE::cv;
    
    $cv->begin;
    my $MultiDown = AnyEvent::MultiDownload->new( 
        url     => 'http://xxx1',
        dlname  => "/tmp/file2",
        on_seg_finish => sub {
            my ($hdr, $seg_path, $size, $cb) = @_;
            $cb->(1);
        },
        on_finish => sub {
            my $len = shift;
            $cv->end;
        },
        on_error => sub {
            my $error = shift;
            $cv->end;
        }
    );
    $MultiDown->multi_get_file;
    
    $cv->begin;
    my $MultiDown1 = AnyEvent::MultiDownload->new( 
        dlname  => "/tmp/file1",
        url     => 'http://xxx', 
        on_finish => sub {
            my $len = shift;
            $cv->end;
        },
        on_error => sub {
            my $error = shift;
            $cv->end;
        }
    );
    $MultiDown1->multi_get_file;
    
    $cv->recv;

以上是同时下载多个文件的实例.

=head1 METHODS

创建一个多下载的对象.

    my $MultiDown = AnyEvent::MultiDownload->new( 
            url     => 'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 
            mirror  => ['http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso'],
            dlname  => $dlname,
            seg_size => 1 * 1024 * 1024, # 1M
            on_seg_finish => sub {
                my ($hdr, $seg_path, $size, $cb) = @_;
                $cb->(1);
            },
            on_finish => sub {
                my $len = shift;
                $cv->send;
            },
            on_error => sub {
                my $error = shift;
                $cv->send;
            },
    
    );

=over 9

=item url => 下载的主地址

这个是下载用的 master 的地址, 是主地址,这个参数必须有.

=item dlname => 下载后的存放地址

这个地址用于指定,下载完了,存放在什么位置. 这个参数必须有.

=item mirror => 镜象地址

这个是可以用来做备用地址和分块下载时用的地址. 需要一个数组引用,其中放入这个文件的其它用于下载的地址. 本参数不是必须的.

=item seg_size => 下载块的大小

默认这个 seg_size 是指每次取块的大小,默认是 2M 一个块, 这个参数会给文件按照 2M 的大小来切成一个个块来下载并合并.本参数不是必须的.

=item on_seg_finish => 每块的下载完成回调

当每下载完 1M 时,会回调一次, 你可以用于检查你的下载每块的完整性,这个时候只有 200 和 206 响应的时候才会回调,回调传四个参数,本块下载时响应的 header, 下载的块的临时文件位置, 下载块的大家,检查完后的回调.如果回调为 1 证明检查结果正常,如果为 0 证明检查失败,会在次重新下载本块. 默认模块也会帮助检查大小,所以大小不用对比和检查了,可以给每块的 MD5 记录下来,使用这个来对比. 本参数不是必须的.如果没有这个回调默认检查大小正确.

=item on_finish

当整个文件下载完成时的回调, 下载完成的回调会传一个下载的文件大小的参数过来.这个回调必须存在.

=item on_error

当整个文件下载过程出错时回调,这个参数必须存在,因为不能保证每次下载都能正常.

=item timeout

下载多久算超时,可选参数,默认为 60s.

=item recurse 重定向

如果请求过程中有重定向,可以最多重定向多少次.

=back

=head2 ->multi_get_file()

事件开始的方法.只有调用这个函数时,这个下载的事件才开始执行.

=head1 AUTHOR

扶凯 fukai <iakuf@163.com>

=cut
