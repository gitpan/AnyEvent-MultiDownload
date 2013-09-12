#!/usr/bin/perl
package AnyEvent::MultiDownload;
use strict;
use AnyEvent::HTTP;
use AnyEvent::Util;
use AnyEvent::Socket;
use AnyEvent::IO;
use AE;
use Moo;
use File::Temp;
use File::Copy;
use File::Basename;
use List::Util qw/shuffle/;

our $VERSION = '0.50';

has content_file => (
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

has fh       => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my $out = File::Temp->new(UNLINK => 1); 
        $out->autoflush(1);
        return $out;
    },
);

has retry_interval => is => 'rw', default => sub { 3 };
has max_retries => is => 'rw', default => sub { 5 };
has seg_size    => is => 'rw', default => sub { 1 * 1024 * 1024 };
has timeout     => is => 'rw', default => sub { 60 };
has recurse     => is => 'rw', default => sub { 6 }; 
has headers      => is => 'rw', default => sub {{}};
has tasks       => is => 'rw', default => sub { [] };
has max_per_host  => is => 'rw', default => sub { 8 };

sub BUILD {
    my $self = shift; 
};

sub get_file_length {
    my $self = shift;
    my $cb   = shift;
    

    my ($len, $hdr, $body);
    my $cv = AE::cv {
        if ( $len ) {
            $cb->($len, $hdr) 
        }
        else{
            $hdr ? $self->on_error->("连接失败, 响应 $hdr->{Status}, 内容 $body.") 
                    : $self->on_error->("远程地址没有响应.");
        }
    };

    my $fetch_len; $fetch_len = sub {
        my $retry = shift || 0;
        my $ev; $ev = http_head $self->url,
            headers => $self->headers, 
            timeout => $self->timeout,
            recurse => $self->recurse,
            sub {
                ($body, $hdr) = @_;
                undef $ev;
                if ($retry > $self->max_retries) {
                    $self->on_error->("连接失败, 响应 $hdr->{Status}, 内容 $body.");
                    return;
                }
                if ($hdr->{Status} =~ /^2/) {
                    $len = $hdr->{'content-length'};
                }
                else {
                    my $w;$w = AE::timer( $self->retry_interval, 0, sub {
                        $fetch_len->(++$retry); 
                        undef $w;
                    });
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

        # 用于做事件同步
        my $cv = AE::cv { 
            my $cv = shift;
            $self->move_to;
            $self->on_finish->($self->size);
        };

        # 事件开始, 但这个回调会在最后才调用.
        $cv->begin;
        for my $range (@$ranges) {
            $cv->begin;
            $self->fetch->( $cv, $self->shuffle_url, $range, 0 ) ;
        }
        $cv->end;
    });
}


sub shuffle_url {
    my $self = shift;
    my @urls;
    @urls = @{ $self->mirror } if $self->has_mirror;
    push @urls, $self->url;
    return (shuffle @urls)[0];
}

sub on_body {
    my ($self, $chunk) = @_; 
    return sub {
        my ($partial_body, $hdr) = @_;
        return 0 unless ($hdr->{Status} == 206 || $hdr->{Status} == 200);
        my $task_chunk = $self->tasks->[$chunk];

        seek($self->fh, $task_chunk->{pos}, 0); 
        syswrite($self->fh, $partial_body);

        # 写完的记录
        my $len = length($partial_body);
        $task_chunk->{pos}   += $len;
        $task_chunk->{size}  += $len;
        return 1;
    }
}
sub fetch {
    my $self = shift;
    return sub {
        my ($cv, $url, $range, $retry) = @_; 
        $retry ||= 0;
        my $ofs  = $range->{ofs};
        my $tail = $range->{tail};
        my $chunk = $range->{chunk};
        local $AnyEvent::HTTP::MAX_PER_HOST = $self->max_per_host; 
        my $buf;
        my $ev; $ev = http_get $url,
            timeout     => $self->timeout,
            recurse     => $self->recurse,
            persistent  => 1,
            keepalive   => 1,
            headers     => { 
                %{ $self->headers }, 
                Range => "bytes=$ofs-$tail" 
            },
            on_body => $self->on_body($chunk),
            sub {
                my ($hdl, $hdr) = @_;

                my $status = $hdr->{Status};

                $cv->end;
                undef $ev;

                if ( $retry > $self->max_retries ) {
                    $self->on_error->("地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载失败");
                }

                if ($status == 200 || $status == 206 || $status == 416) {
                    my $size = $self->tasks->[$chunk]{size};
                    if ($size == ($tail-$ofs+1)) {
                        $self->on_seg_finish->( $hdl, $self->get_chunk($ofs, $self->seg_size), $size, $range, sub {
                            my $result = shift;
                            if (!$result) {
                                $self->retry($cv, $range, $retry);
                                return;
                            }
                            AE::log debug => "地址 $url 的块 $range->{chunk} 范围 bytes=$ofs-$tail 下载完成";
                        });
                        return;
                    }
                } 
                $self->retry($cv, $range, $retry);
            };
    };
}

sub retry {
    my ($self, $cv, $range, $retry) = @_;
    my $chunk = $range->{chunk};
    my $w;$w = AE::timer( $self->retry_interval, 0, sub {
        AE::log warn => "地址块 $range->{chunk} 范围 bytes=$range->{ofs}  $range->{tail} 下载失败, 第 $retry 次重试";
        $cv->begin;
        $self->tasks->[$chunk]->{pos} = $self->tasks->[$chunk]->{ofs}; # 重下本块时要 seek 回零
        $self->fetch->( $cv, $self->shuffle_url, $range, ++$retry );
        undef $w;
    });
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
        my $task  = { 
            ofs   => $ofs,
            tail  => $tail,
            chunk => $chunk,
            pos   => $ofs,
            size  => 0,
        }; 

        $self->tasks->[$chunk] = $task; 
        push @ranges, $task;
        $chunk++;
    }
    return \@ranges;
}

sub get_chunk {
  my ($self, $offset, $max) = @_; 
  $max ||= 1024 * 1024;

  my $handle = $self->fh;
  $handle->sysseek($offset, SEEK_SET);

  my $buffer;
  $handle->sysread($buffer, $max); 

  return $buffer;
}

sub move_to {
    my $self = shift;

    close $self->fh;
    my $dir  = File::Basename::dirname( $self->content_file );
    if (! -e $dir ) {
        if (! File::Path::make_path( $dir ) || ! -d $dir ) {
            my $e = $!;
        }
    }
    File::Copy::copy( $self->fh->filename, $self->content_file )
          or die "Failed to rename $self->fh->filename to $self->content_file: $!";

    delete $self->{fh};
}

sub size {
  return 0 unless defined(my $file = shift->content_file);
  return -s $file;
}

1;

__END__

=pod
 
=encoding utf8

=head1 NAME

AnyEvent::MultiDownload - 非阻塞的多线程多地址文件下载的模块

=head1 SYNOPSIS

这是一个全非阻塞的多线程多地址文件下载的模块, 可以象下面这个应用一样, 同时下载多个文件, 并且整个过程都是异步事件解发, 不会阻塞主进程.

下面是个简单的例子, 同时从多个地址下载同一个文件.

    use AE;
    use AnyEvent::MultiDownload;

    my @urls = (
        'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso',
        'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso',
    );
    
    my $cv = AE::cv;
    my $MultiDown = AnyEvent::MultiDownload->new( 
        url     => pop @urls, 
        mirror  => \@urls, 
        content_file  => '/tmp/ubuntu.iso',
        seg_size => 1 * 1024 * 1024, # 1M
        on_seg_finish => sub {
            my ($hdr, $seg, $size, $chunk, $cb) = @_;
            $cb->(1);
        },
        on_finish => sub {
            my $len = shift;
            $cv->send;
        },
        on_error => sub {
            my $error = shift;
            $cv->send;
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
        content_file  => "/tmp/file2",
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
        content_file  => "/tmp/file1",
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

    my @urls = (
        'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso',
        'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso',
    );
    my $MultiDown = AnyEvent::MultiDownload->new( 
            url     => shift @urls, 
            mirror  => \@urls, 
            content_file  => $content_file,
            seg_size => 1 * 1024 * 1024, # 1M
            on_seg_finish => sub {
                my ($hdr, $seg_path, $size, $chunk,  $cb) = @_;
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

=over 8

=item url => 下载的主地址

这个是下载用的 master 的地址, 是主地址, 这个参数必须有.

=item content_file => 下载后的存放地址

这个地址用于指定, 下载完了, 存放在什么位置. 这个参数必须有.

=item mirror => 镜象地址

这个是可以用来做备用地址和分块下载时用的地址. 需要一个数组引用, 其中放入这个文件的其它用于下载的地址. 如果块下载失败会自动切换成其它的地址下载. 本参数不是必须的.

=item seg_size => 下载块的大小

默认这个 seg_size 是指每次取块的大小, 默认是 1M 一个块, 这个参数会给文件按照 1M 的大小来切成一个个块来下载并合并. 本参数不是必须的.

=item retry_interval => 重试的间隔 

重试的间隔, 默认为 3 s.

=item max_retries => 最多重试的次数

重试每个块所能重试的次数, 默认为 5 次.

=item max_per_host => 每个主机最多的连接数量

目前模块没有开发总连接数控制, 主要原因是.多线路为了快,所以控制单个主机的并发比控制总体好. 默认为 8.

=item headers => 自定义的 header

如果你想自己定义传送的 header , 就在这个参数中加就好了, 默认是一个哈希引用.

=item timeout

下载多久算超时, 可选参数, 默认为 60s.

=item recurse 重定向

如果请求过程中有重定向, 可以最多重定向多少次.

=back

=head2 multi_get_file()

事件开始的方法. 只有调用这个函数时, 这个下载的事件才开始执行.

=head1 callback

=head2 on_seg_finish

当每下载完 1M 时,会回调一次, 你可以用于检查你的下载每块的完整性, 这个时候只有 200 和 206 响应的时候才会回调.

回调传四个参数, 本块下载时响应的 header, 下载的块的实体二进制内容, 下载块的大小, 当前是第几块 检查完后的回调. 这时如果回调为 1 证明检查结果正常, 如果为 0 证明检查失败, 会在次重新下载本块. 

默认模块会帮助检查大小, 所以大小不用对比和检查了, 可以给每块的 MD5 记录下来, 使用这个来对比. 本参数不是必须的. 如果没有这个回调默认检查大小正确.

=head2 on_finish

当整个文件下载完成时的回调, 下载完成的回调会传一个下载的文件大小的参数过来. 这个回调必须存在.

=head2 on_error

当整个文件下载过程出错时回调, 这个参数必须存在, 因为不能保证每次下载都能正常.


=head1 AUTHOR

扶凯 fukai <iakuf@163.com>

=cut
