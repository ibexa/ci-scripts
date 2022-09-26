<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Tests\ContiniousIntegrationScripts\Command;

use Ibexa\ContiniousIntegrationScripts\Command\RunRegressionCommand;
use PHPUnit\Framework\Assert;
use PHPUnit\Framework\TestCase;

class RunRegressionCommandTest extends TestCase
{
    public function testIsInitializable(): void
    {
        Assert::assertInstanceOf(RunRegressionCommand::class, new RunRegressionCommand());
    }
}
