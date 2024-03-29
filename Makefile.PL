use strict;
use warnings;
use ExtUtils::MakeMaker;
 
WriteMakefile(
    NAME                => 'AnyEvent::MultiDownload',
    AUTHOR              => '扶凯 <iakuf@163.com>',
    EXE_FILES           => ['bin/md-request'],
    PL_FILES            => {},
    LICENSE             => "perl",
    DISTNAME            => 'AnyEvent-MultiDownload',
    VERSION_FROM        => 'lib/AnyEvent/MultiDownload.pm',
    PREREQ_PM => {
        'Test::More' => 0,
        'AE'    => 0,
        'EV'    => 0,
        'Moo'   => 0,
        'AnyEvent::HTTP'    => 2.21,
        'AnyEvent::Util'    => 0,
        'AnyEvent::Socket'  => 0,
        'AnyEvent::Digest'  => 0.0.5,
        'List::Util'        => 0,
        'File::Temp' => 0,
        'File::Copy' => 0,
        'File::Basename' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'AnyEvent-MultiDownload-*' },
    META_MERGE => {
        resources => {
            repository => 'https://github.com/iakuf/anyevent-multidownload',
        },
    },
);
