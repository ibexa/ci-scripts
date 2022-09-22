<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Tests\ContiniousIntegrationScripts\Command;

use Ibexa\ContiniousIntegrationScripts\Command\LinkDependenciesCommand;
use Ibexa\ContiniousIntegrationScripts\Helper\ComposerLocalTokenProvider;
use org\bovigo\vfs\vfsStream;
use PHPUnit\Framework\Assert;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Console\Tester\CommandTester;

class LinkDependenciesCommandTest extends TestCase
{
    private const FILENAME = 'dependencies.json';

    /** @var \Symfony\Component\Console\Tester\CommandTester */
    private $commandTester;

    private const EXPECTED_FILE_CONTENT = <<<FILE
    {
        "recipesEndpoint": "https://api.github.com/repos/ibexa/recipes-dev/contents/index.json?ref=flex/pull-24",
        "packages": [
            {
                "requirement": "dev-temp_2.3_to_4.2 as 4.2.x-dev",
                "repositoryUrl": "https://github.com/ibexa/admin-ui",
                "package": "ibexa/admin-ui",
                "shouldBeAddedAsVCS": false
            },
            {
                "requirement": "dev-known-issue-message as 4.3.x-dev",
                "repositoryUrl": "https://github.com/ibexa/behat",
                "package": "ibexa/behat",
                "shouldBeAddedAsVCS": false
            }
        ]
    }
    FILE;

    /** @var \org\bovigo\vfs\vfsStreamDirectory */
    private $fileSystemRoot;

    protected function setUp(): void
    {
        $tokenProvider = $this->createMock(ComposerLocalTokenProvider::class);
        $tokenProvider->method('getGithubToken')->willReturn(null);
        $this->fileSystemRoot = vfsStream::setup();
        $this->commandTester = new CommandTester(
            new LinkDependenciesCommand($this->fileSystemRoot->url(), $tokenProvider)
        );
    }

    public function testGeneratesCorrectDependenciesJsonFile(): void
    {
        $this->commandTester->setInputs([
            '3',
            'https://github.com/ibexa/admin-ui/pull/577',
            'https://github.com/ibexa/recipes-dev/pull/24',
            'https://github.com/ibexa/behat/pull/37',
        ]);

        $this->commandTester->execute([]);

        Assert::assertTrue($this->fileSystemRoot->hasChild(self::FILENAME));
        Assert::assertEquals(
            self::EXPECTED_FILE_CONTENT,
            file_get_contents($this->fileSystemRoot->getChild(self::FILENAME)->url())
        );
    }
}
